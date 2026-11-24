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
import 'dart:io';

import 'package:dim_client/common.dart' show ID;
import 'package:magpipe/magpipe.dart';

import 'pipeline.dart';
import 'speedometer.dart';

/// Pipe manager: owns the peer registry (did -> pipelines), resolves
/// inbound packets back to their owning did(s), re-issues bridge
/// permits and revives dead direct links. Measuring and picking the
/// pipes is delegated to the [PipeSpeedometer] (speedometer.dart,
/// vomp/rtt.md): this class hands it each registered peer and asks it
/// back for the fastest pipe.
///
/// Embedded in MagpieClient and driven by its keepAlive() - the tick
/// runs BEFORE hub.keepAlive, so the probe PING refreshes the pipe's
/// last-send time and the hub adds no duplicate heartbeat.
class PipeManager with PayloadMixIn {
  PipeManager({required MagHub hub, this.onPipelinesReady})
      : _hub = hub, _speedo = PipeSpeedometer(hub: hub);

  // tunings (vomp/client.md section 7)
  static const int reprobeInterval = 30; // seconds
  static const int reprobeLimit = 5;

  /// cap of the bridge entries per peer (fake-bridge resource attack);
  /// when a new entry overflows it, the worst-ranked one is dropped
  static const int maxBridgesPerPeer = 8;

  /// cap of the direct endpoints per peer, same policy as the bridges
  static const int maxSocketsPerPeer = 8;

  /// min interval between two send-failure fallback rounds per receiver
  static const int fallbackInterval = 10; // seconds

  /// Fired when the first probe PONG of a peer arrives after none was
  /// ready: the data-plane 'connected' transition.
  void Function(ID did)? onPipelinesReady;

  final MagHub _hub;
  final PipeSpeedometer _speedo;

  /// did -> pipelines
  final Map<ID, PeerPipelines> _peers = {};

  /// peers with at least one ready pipe (last known state)
  final Set<ID> _connected = {};

  /// reverse indexes: link endpoint -> owner did(s)
  final Map<SocketAddress, Set<ID>> _directOwners = {};
  final Map<SocketAddress, Set<ID>> _bridgeOwners = {};

  /// every bridge endpoint I dialed (my own registrations included)
  final Map<SocketAddress, _BridgeState> _bridgeStates = {};

  /// direct link reviving (rate limited, capped)
  final Map<SocketAddress, int> _directProbes = {};
  final Map<SocketAddress, DateTime?> _lastProbe = {};

  /// last send-failure fallback round per receiver
  final Map<ID, DateTime> _fallbacks = {};

  /// Register the peer's port info (from its 'dial'/'accept' signaling):
  /// dial every bridge server and every direct endpoint listed there.
  /// Both lists are deduped by endpoint; existing links are reused.
  void updatePipelines(ID did, Iterable<BridgeEntry> bridges, Iterable<SocketEntry> sockets) {
    var peer = _peers[did];
    if (peer == null) {
      peer = PeerPipelines(did);
      _peers[did] = peer;
    }
    for (var entry in bridges) {
      if (peer.mergeBridge(entry)) {
        _owners(_bridgeOwners, entry.endpoint).add(did);
        _connectBridge(entry.endpoint);
      }
    }
    for (var entry in sockets) {
      if (peer.mergeSocket(entry)) {
        _owners(_directOwners, entry.endpoint).add(did);
        _connectDirect(entry.endpoint);
      }
    }
  }

  /// Cap the peer's bridge entries at [maxBridgesPerPeer] (client.md
  /// section 7 - fake-bridge resource attack). Runs in the tick, NOT at
  /// registration time: eviction waits for evidence - a bridge is
  /// dropped only when provably dead (handshake failed or budget
  /// exhausted) or the slowest among the measured, so fresh entries
  /// always get their chance to be measured. The shared link stays:
  /// other peers may live on the same bridge server.
  void _trimBridges(PeerPipelines peer, DateTime now) {
    while (peer.bridges.length > maxBridgesPerPeer) {
      final worst = _speedo.worstBridge(peer, now);
      if (worst == null) {
        break; // everything left is still in its grace period
      }
      final bid = peer.bridges[worst]!.bid;
      peer.bridges.remove(worst);
      _speedo.dropBridge(worst, bid);
    }
  }

  /// Cap the peer's direct endpoints at [maxSocketsPerPeer], same
  /// evidence-based eviction as [_trimBridges]. The reverse index is
  /// cleaned along (resolve and the revive loop scan it directly), and
  /// an endpoint left with no owner gets its link disconnected, so an
  /// evicted endpoint leaves the revive loop for good.
  void _trimSockets(ID did, PeerPipelines peer, DateTime now) {
    while (peer.sockets.length > maxSocketsPerPeer) {
      final worst = _speedo.worstSocket(peer, now);
      if (worst == null) {
        break; // everything left is still in its grace period
      }
      peer.sockets.remove(worst);
      final owners = _directOwners[worst];
      if (owners != null) {
        owners.remove(did);
        if (owners.isNotEmpty) {
          continue; // another did still lives on this endpoint
        }
        _directOwners.remove(worst);
      }
      _directProbes.remove(worst);
      _lastProbe.remove(worst);
      _hub.disconnect(worst); // orphaned: free the link
      _speedo.dropDirect(worst);
    }
  }

  /// Register on my own bridge servers: dial each of them (B=1) so that
  /// myBridges / mySockets carry my port info for the first dial.
  /// Idempotent per endpoint.
  void connectBridges(List<SocketAddress> servers) {
    for (var remote in servers) {
      _bridgeStates.putIfAbsent(remote, _BridgeState.new);
      _hub.connectBridge(remote);
    }
  }

  /// Drop every registration (the shared socket stays owned by the hub).
  void close() {
    _peers.clear();
    _directOwners.clear();
    _bridgeOwners.clear();
    _bridgeStates.clear();
    _directProbes.clear();
    _lastProbe.clear();
    _fallbacks.clear();
    _connected.clear();
  }

  /// Tear down everything registered for [did] (on hangup): direct
  /// endpoints with no other owner get their links disconnected, bridge
  /// pipes are removed by the peer's bid ('DENY' + local pipe drop) -
  /// the bridge links themselves stay, they are shared (my own
  /// registrations and other peers may live on the same server).
  void removePipelines(ID did) {
    final peer = _peers.remove(did);
    if (peer == null) {
      return;
    }
    for (var remote in peer.sockets.keys) {
      final owners = _directOwners[remote];
      if (owners != null) {
        owners.remove(did);
        if (owners.isNotEmpty) {
          continue; // another did still lives on this endpoint
        }
        _directOwners.remove(remote);
      }
      _directProbes.remove(remote);
      _lastProbe.remove(remote);
      _hub.disconnect(remote);
      _speedo.dropDirect(remote);
    }
    for (var entry in peer.bridges.entries) {
      final remote = entry.key;
      final owners = _bridgeOwners[remote];
      if (owners != null) {
        owners.remove(did);
        if (owners.isNotEmpty) {
          continue;
        }
        _bridgeOwners.remove(remote);
      }
      final bid = entry.value.bid;
      _hub.getBridgeLink(remote)?.deny([bid]); // 'DENY' + drop local pipe
      _speedo.dropBridge(remote, bid);
    }
    _fallbacks.remove(did);
    _connected.remove(did);
  }

  /// My own registration on every ready bridge: entries of my
  /// 'magpie-bridges' list for dial/accept signaling.
  List<BridgeEntry> get myBridges {
    final list = <BridgeEntry>[];
    for (var remote in _bridgeStates.keys) {
      final link = _hub.getBridgeLink(remote);
      if (link == null || !link.ready || link.bid == 0) {
        continue;
      }
      list.add(BridgeEntry(host: remote.host, port: remote.port, bid: link.bid));
    }
    return list;
  }

  /// The NAT mappings my bridges observed: entries of my 'magpie-sockets'
  /// list for dial/accept signaling (deduped, all-cone NAT shares one).
  List<SocketEntry> get mySockets {
    final seen = <String>{};
    final list = <SocketEntry>[];
    for (var remote in _bridgeStates.keys) {
      final link = _hub.getBridgeLink(remote);
      final observed = link?.observedAddress;
      if (observed == null) {
        continue;
      }
      final addr = _parseObserved(observed);
      if (addr == null) {
        continue;
      }
      if (!seen.add('${addr.$1.address}:${addr.$2}')) {
        continue;
      }
      list.add(SocketEntry(host: addr.$1, port: addr.$2));
    }
    return list;
  }

  /// The fastest ready pipe to the receiver, ranked by the speedometer
  /// (direct first, then by measured rtt). Returns null when the peer
  /// is not registered or no pipe is ready - in the latter case a
  /// rate-limited fallback round re-dials the peer's endpoints
  /// (client.md section 4).
  MagPipe? fastestPipe(ID receiver) {
    final peer = _peers[receiver];
    if (peer == null) {
      return null;
    }
    final pipe = _speedo.fastestPipe(peer);
    if (pipe == null) {
      _connected.remove(receiver); // back to 'connecting' state
      _fallback(receiver, peer);
    }
    return pipe;
  }

  /// Send-failure fallback: the receiver has registered endpoints yet
  /// no ready pipe - re-kick the dialing of every endpoint (missing
  /// links get dialed, stuck ones dropped and re-dialed), so the next
  /// ticks find a path. Rate limited to one round per receiver per
  /// [fallbackInterval].
  void _fallback(ID receiver, PeerPipelines peer) {
    final now = DateTime.now();
    final last = _fallbacks[receiver];
    if (last != null && now.difference(last).inSeconds < fallbackInterval) {
      return;
    }
    _fallbacks[receiver] = now;
    for (var remote in peer.bridges.keys) {
      if (_hub.getBridgeLink(remote) == null) {
        _connectBridge(remote);
      }
    }
    for (var remote in peer.sockets.keys) {
      final link = _hub.getDirectLink(remote);
      if (link == null) {
        _connectDirect(remote);
      } else if (link.closed || link.needsReconnect(now)) {
        _redial(now, remote);
      }
    }
  }

  /// Resolve the owning did(s) of a received packet: direct links match
  /// by the peer endpoint; bridge links also require the packet's source
  /// bid to be the one the peer announced (vomp/client.md section 5).
  Set<ID>? _resolveOwners(MagLink link, Packet packet) {
    final remote = link.remoteAddress;
    if (link is DirectLink) {
      return _directOwners[remote];
    }
    // bridge link (B=1): the packet's source bid must be the one the
    // peer announced in its 'magpie-bridges' entry on this bridge
    final owners = _bridgeOwners[remote];
    if (owners == null || owners.isEmpty) {
      return null;
    }
    for (var did in owners) {
      final entry = _peers[did]?.bridges[remote];
      if (entry != null && entry.bid == packet.source) {
        return {did};
      }
    }
    return null;
  }

  /// Feed every inbound packet here: a PONG with a valid echoed
  /// 'start_time' samples its pipe's rtt (speedometer) and marks the
  /// resolved peer(s) as connected - the first one after a 'none ready'
  /// period fires [onPipelinesReady] -; a bridge 'FAIL' penalizes the
  /// pipe it concerns (maglink.md #7: the upper layer decides). Either
  /// way the packet resolves back to its owner did(s).
  Set<ID>? onPacketReceived(Packet packet, MagLink link) {
    final senders = _resolveOwners(link, packet);
    if (packet.command == Command.PONG) {
      if (_speedo.onPongReceived(packet, link) && senders != null) {
        for (var did in senders) {
          if (_connected.add(did)) {
            onPipelinesReady?.call(did);
          }
        }
      }
    } else if (packet.command == Command.FAIL && link is BridgeLink) {
      _onFail(packet, link.remoteAddress);
    }
    return senders;
  }

  /// Bridge 'FAIL' with 'src-target'/'sources' (maglink.md #7): the
  /// server could not forward to those bids - peer offline, or a stale
  /// bid after the peer's re-handshake. Sample the matching pipes at
  /// the rtt cap, so the ranking drops them until a fresh PONG proves
  /// the path again; recovery from the peer's side stays the DIMP
  /// 'update' signaling's job (client.md section 8).
  void _onFail(Magpie packet, SocketAddress remote) {
    final info = decodePayload(packet.payload);
    final bids = <int>{};
    final target = info['src-target'];
    if (target is int) {
      bids.add(target);
    }
    final sources = info['sources'];
    if (sources is List) {
      for (var bid in sources) {
        if (bid is int) {
          bids.add(bid);
        }
      }
    }
    for (var did in _bridgeOwners[remote] ?? const <ID>{}) {
      final entry = _peers[did]?.bridges[remote];
      if (entry != null && bids.contains(entry.bid)) {
        _speedo.penalizeBridge(remote, entry.bid);
      }
    }
  }

  /// Most likely a peer's direct-connect 'SYN?': complete the handshake
  /// when the endpoint belongs to a registered peer, else ignore.
  void onUnknownPeer(SocketAddress remote) {
    if (_directOwners.containsKey(remote)) {
      _connectDirect(remote);
    }
  }

  //
  //   Internals
  //

  /// Called before hub.keepAlive: re-issue the bridge permits ('ACPT')
  /// whenever the handshake has (re-)completed ('reconnect' clears pipes
  /// and permits server-side, and 'accept' is a no-op while
  /// re-handshaking, so each completion must be followed up -
  /// maglink.md section 2, case #8), probe every pipe, revive dead
  /// direct links.
  void tick(DateTime now) {
    _reaccept(now);
    for (var entry in _peers.entries) {
      _speedo.probePeer(entry.value);
      _trimBridges(entry.value, now);
      _trimSockets(entry.key, entry.value, now);
    }
    _reviveDirects(now);
  }

  void _reaccept(DateTime now) {
    for (var remote in _bridgeStates.keys) {
      final link = _hub.getBridgeLink(remote);
      if (link == null || !link.ready || link.bid == 0) {
        continue;
      }
      final state = _bridgeStates[remote]!;
      if (link.needsReconnect(now)) {
        state.accepted = null; // permits died with the old session
        continue;
      }
      final bids = _bidsOnBridge(remote);
      if (bids.isEmpty) {
        continue;
      }
      final accepted = state.accepted;
      if (accepted != null && _sameBids(accepted, bids)) {
        continue;
      }
      link.accept(bids.toList());
      state.accepted = bids;
    }
  }

  /// The peer bids that must be permitted on this bridge: every did
  /// registered with a 'magpie-bridges' entry on it.
  Set<int> _bidsOnBridge(SocketAddress remote) {
    final bids = <int>{};
    for (var did in _bridgeOwners[remote] ?? const <ID>{}) {
      final entry = _peers[did]?.bridges[remote];
      if (entry != null && entry.bid != 0) {
        bids.add(entry.bid);
      }
    }
    return bids;
  }

  /// Revive dead direct links: the hub only retries the handshake within
  /// its budget, past it the link goes quiet - re-dial from scratch,
  /// rate limited and capped (vomp/client.md section 3.4).
  void _reviveDirects(DateTime now) {
    for (var remote in _directOwners.keys) {
      final link = _hub.getDirectLink(remote);
      if (link == null) {
        _connectDirect(remote); // dropped earlier: dial a fresh link
        continue;
      }
      if (link.ready) {
        _directProbes[remote] = 0;
        continue;
      }
      if (link.closed || link.needsReconnect(now)) {
        _reprobe(now, remote);
      }
    }
  }

  void _reprobe(DateTime now, SocketAddress remote) {
    final last = _lastProbe[remote];
    if (last != null &&
        now.difference(last).inSeconds < reprobeInterval) {
      return;
    }
    _redial(now, remote);
  }

  /// Drop the stuck link and dial a fresh one (re-grants the handshake
  /// budget); counts against the endpoint's re-probe cap, shared by the
  /// passive tick path and the send-failure fallback.
  void _redial(DateTime now, SocketAddress remote) {
    final count = (_directProbes[remote] ?? 0) + 1;
    if (count > reprobeLimit) {
      return; // stays dead until the peer's next signaling arrives
    }
    _directProbes[remote] = count;
    _lastProbe[remote] = now;
    _hub.disconnect(remote); // drop the stuck link
    _connectDirect(remote);  // ... and dial a fresh link (resets its budget)
  }

  /// Dial the bridge server (B=1) and start bookkeeping: idempotent,
  /// an already dialed endpoint is reused as-is.
  void _connectBridge(SocketAddress remote) {
    _bridgeStates.putIfAbsent(remote, _BridgeState.new);
    _hub.connectBridge(remote);
  }

  /// Dial the peer's direct endpoint (B=0) and start bookkeeping:
  /// idempotent, an already dialed endpoint is reused as-is.
  void _connectDirect(SocketAddress remote) {
    _directProbes[remote] ??= 0;
    _lastProbe[remote] ??= DateTime.now();
    _hub.connect(remote);
  }

  static Set<ID> _owners(Map<SocketAddress, Set<ID>> owners, SocketAddress remote) =>
      owners.putIfAbsent(remote, () => {});

  static bool _sameBids(Set<int> a, Set<int> b) =>
      a.length == b.length && a.containsAll(b);

  /// 'ip:port' (or '[ipv6]:port') as carried by the 'SYN!' 'UDP' field.
  static (InternetAddress, int)? _parseObserved(String observed) {
    final i = observed.lastIndexOf(':');
    if (i < 0) {
      return null;
    }
    final port = int.tryParse(observed.substring(i + 1));
    if (port == null || port <= 0 || port > 0xFFFF) {
      return null;
    }
    var host = observed.substring(0, i);
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    final addr = InternetAddress.tryParse(host);
    if (addr == null) {
      return null;
    }
    return (addr, port);
  }
}

/// Per bridge endpoint bookkeeping: the bid set permitted in the current
/// session (null = never accepted since the last handshake).
class _BridgeState {
  Set<int>? accepted;
}
