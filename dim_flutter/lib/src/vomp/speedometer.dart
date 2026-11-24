/* license: https://mit-license.org
 *
 *  Magpie Bridge
 *
 *                               Written in 2026 by Moky <albert.moky@gmail.com>
 *
 * ==============================================================================
 * The MIT License (MIT)
 *
 * Copyright (c) 2026 Albert Moky
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 * ==============================================================================
 */
import 'package:magpipe/magpipe.dart';

import 'pipeline.dart';

/// Speedometer: measures the rtt of every pipe with PING probes carrying
/// a 'start_time' field (echoed back by the PONG) and keeps a
/// sliding-average sample per pipe. Holding the hub, it enumerates a
/// peer's ready pipes itself: [probePeer] pings each one, [fastestPipe]
/// ranks them (direct first, then by rtt). The peer registry
/// (did -> pipelines) stays in the PipeManager (manager.dart).
///
/// Stateless filtering: only these probes carry 'start_time' (the
/// link-layer heartbeats ping with 'time' only, magpipe direct.dart /
/// bridge.dart), so a PONG with a valid echoed 'start_time' is always
/// the answer to one of ours - no in-flight bookkeeping is needed, and
/// duplicates can never cross over.
class PipeSpeedometer with PayloadMixIn {
  PipeSpeedometer({required MagHub hub}) : _hub = hub;

  final MagHub _hub;

  // tunings (vomp/rtt.md)
  static const double rttCapMs = 3000.0;
  static const double rttAlpha = 0.25;

  /// sliding-average rtt samples, keyed by the pipe's addressing
  final Map<String, double> _rtt = {};

  /// Send a PING probe per ready pipe of the peer: the receiving pipe
  /// answers PONG with the payload echoed, which yields the sample.
  void probePeer(PeerPipelines peer) {
    for (var remote in peer.sockets.keys) {
      final link = _hub.getDirectLink(remote);
      if (link == null || !link.ready) {
        continue;
      }
      final pipe = link.getPipe(0);
      if (pipe == null) {
        continue;
      }
      _probe(pipe);
    }
    for (var remote in peer.bridges.keys) {
      final entry = peer.bridges[remote]!;
      final link = _hub.getBridgeLink(remote);
      if (link == null || !link.ready || link.bid == 0) {
        continue;
      }
      final pipe = link.getPipe(entry.bid);
      if (pipe == null) {
        continue; // permit not granted yet
      }
      _probe(pipe);
    }
  }

  /// Send a PING probe carrying the 'start_time' field: the receiving
  /// pipe answers PONG with the payload echoed, which yields the sample.
  void _probe(MagPipe pipe) {
    final seconds = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final encoded = encodePayload({
      'time': seconds,
      'start_time': seconds,
    });
    Magpie packet;
    if (pipe is BridgePipe) {
      final bp = pipe;
      packet = BridgePacket.create(
        ack: 0, target: bp.target, source: bp.source,
        sn: 0, index: 0, count: 1,
        command: Command.PING, payload: encoded,
      );
    } else {
      packet = DirectPacket.create(
        ack: 0, sn: 0, index: 0, count: 1,
        command: Command.PING, payload: encoded,
      );
    }
    pipe.sendPacket(packet);
  }

  /// The fastest ready pipe of the peer: direct first (protocol.md
  /// section 3.4), then by measured rtt (null samples last). Returns
  /// null when no pipe is ready.
  MagPipe? fastestPipe(PeerPipelines peer) {
    final list = <_Candidate>[];
    for (var remote in peer.sockets.keys) {
      final link = _hub.getDirectLink(remote);
      if (link == null || !link.ready) {
        continue;
      }
      final pipe = link.getPipe(0);
      if (pipe == null) {
        continue;
      }
      list.add(_Candidate(pipe: pipe, bridge: false,
        rtt: _rtt[_directKey(remote)]));
    }
    for (var remote in peer.bridges.keys) {
      final link = _hub.getBridgeLink(remote);
      if (link == null || !link.ready || link.bid == 0) {
        continue;
      }
      final bid = peer.bridges[remote]!.bid;
      final pipe = link.getPipe(bid);
      if (pipe == null) {
        continue; // permit not granted yet
      }
      list.add(_Candidate(pipe: pipe, bridge: true,
        rtt: _rtt[_bridgeKey(remote, bid)]));
    }
    if (list.isEmpty) {
      return null;
    }
    list.sort((a, b) {
      if (a.bridge != b.bridge) {
        return a.bridge ? 1 : -1;
      }
      final x = a.rtt, y = b.rtt;
      if (x == null && y == null) return 0;
      if (x == null) return 1;
      if (y == null) return -1;
      return x.compareTo(y);
    });
    return list.first.pipe;
  }

  /// The endpoint of the peer's least useful bridge, or null when
  /// nothing is droppable: provably dead ones go first (handshake
  /// failed or budget exhausted), then the slowest measured. Fresh
  /// entries - still dialing, or ready but not yet measured - are
  /// protected, so eviction never fires before the measurements exist.
  SocketAddress? worstBridge(PeerPipelines peer, DateTime now) => _worst(
      peer.bridges.keys,
      linkOf: _hub.getBridgeLink,
      keyOf: (remote) => _bridgeKey(remote, peer.bridges[remote]!.bid),
      now: now,
  );

  /// The endpoint of the peer's least useful direct pipe, same rules
  /// as [worstBridge].
  SocketAddress? worstSocket(PeerPipelines peer, DateTime now) => _worst(
      peer.sockets.keys,
      linkOf: _hub.getDirectLink,
      keyOf: _directKey,
      now: now,
  );

  SocketAddress? _worst(
    Iterable<SocketAddress> remotes, {
    required BaseLink? Function(SocketAddress remote) linkOf,
    required String Function(SocketAddress remote) keyOf,
    required DateTime now,
  }) {
    SocketAddress? dead, slowest;
    double? slowestRtt;
    for (var remote in remotes) {
      final link = linkOf(remote);
      if (link == null || link.closed || (!link.ready && link.needsReconnect(now))) {
        dead ??= remote; // handshake failed or budget exhausted
        continue;
      }
      final rtt = _rtt[keyOf(remote)];
      if (rtt != null && (slowest == null || rtt > slowestRtt!)) {
        slowest = remote;
        slowestRtt = rtt;
      }
    }
    return dead ?? slowest;
  }

  /// Feed every inbound PONG here: an echoed 'start_time' samples its
  /// pipe's rtt (PONG arrival time - start_time). Returns true when a
  /// valid sample was recorded - i.e. this PONG answers one of our
  /// probes, so the round-trip over its pipe just worked.
  bool onPongReceived(Packet packet, MagLink link) {
    final info = decodePayload(packet.payload);
    final start = info['start_time'];
    if (start is! num) {
      return false; // heartbeat reply / foreign PONG: no sample
    }
    final remote = link.remoteAddress;
    final key = link is BridgeLink
        ? _bridgeKey(remote, packet.source)
        : _directKey(remote);
    final sample = DateTime.now().millisecondsSinceEpoch - start * 1000.0;
    if (sample < 0) {
      return false;
    }
    final capped = sample > rttCapMs ? rttCapMs : sample;
    final old = _rtt[key];
    _rtt[key] = old == null ? capped : old + (capped - old) * rttAlpha;
    return true;
  }

  //
  //   Internals
  //

  /// Forget the sample of one direct pipe (teardown/eviction).
  void dropDirect(SocketAddress remote) => _rtt.remove(_directKey(remote));

  /// Forget the sample of one bridge pipe (teardown/eviction).
  void dropBridge(SocketAddress remote, int bid) =>
      _rtt.remove(_bridgeKey(remote, bid));

  /// Sample the bridge pipe's rtt at the cap: the bridge reported a
  /// forward failure for that bid (peer offline / stale bid) - the
  /// ranking drops the pipe until a fresh PONG proves it again.
  void penalizeBridge(SocketAddress remote, int bid) {
    _rtt[_bridgeKey(remote, bid)] = rttCapMs;
  }

  //
  //   Internals
  //

  /// Probe/rtt key of a direct pipe: the peer's endpoint.
  static String _directKey(SocketAddress remote) =>
      'D:${remote.host.address}:${remote.port}';

  /// Probe/rtt key of a bridge pipe: the bridge endpoint + peer bid.
  static String _bridgeKey(SocketAddress remote, int bid) =>
      'B:${remote.host.address}:${remote.port}:$bid';
}

/// One ready pipe of a peer, collected for the ranking.
class _Candidate {
  _Candidate({required this.pipe, required this.bridge, this.rtt});

  final MagPipe pipe;

  /// B=1 via bridge, or B=0 direct
  final bool bridge;

  /// sliding-average rtt in ms, null = no sample yet
  final double? rtt;

}
