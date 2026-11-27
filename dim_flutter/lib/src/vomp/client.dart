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
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:pnf/enigma.dart' show EnigmaItem;
import 'package:dim_client/common.dart' show ID;
import 'package:dim_client/ok.dart';
import 'package:magpipe/magpipe.dart';

import 'manager.dart';
import 'pipeline.dart';

/// Observer for the application layer.
abstract interface class MagpieClientDelegate {
  /// One packet received through a link: [sender] is resolved from the
  /// registered pipelines and is never null - packets with no owner
  /// (server-origin control on a bridge, stale or foreign bids) are
  /// dropped silently. System commands (handshake waves, FAIL/DONE,
  /// FIN, PING/PONG, COPY) are filtered here too: the app sees only
  /// reliable DATA (C=0) and custom-command packets (C=1, e.g. 'VoMP').
  /// Media decryption and validation are the upper layer's job.
  void onPacketReceived(Packet packet, MagPipe? pipe, MagLink link, {
    required ID sender
  });

  /// My own registration info changed (a bridge handshake completed or
  /// dropped): the next dial/accept should carry the fresh lists. While
  /// a call is active, push the fresh lists to the peer right away via
  /// DIMP (the 'update' act, signaling.md section 8) - don't wait for
  /// the next signaling.
  void onSelfUpdated();

  /// The first pipe to the peer just came back (its probe PONG arrived)
  /// after none was ready: the data-plane 'connected' transition
  /// (protocol.md CONNECTING). Until this fires the peer is not reached
  /// on any path; the media timeouts stay the upper layer's job.
  void onPipelinesReady(ID did);
}

/// Magpie client: the data pipeline manager between the application
/// (VoMP signaling/media) and the link layer (MagHub / BridgeLink /
/// DirectLink).
///
/// Usage:
/// ```
/// var client = MagpieClient();
/// client.updateSecrets(myKeys);                   // pre-shared keys
/// await client.bind();                            // binds the socket,
///                                                 //   starts the ticker
/// client.connectBridges(myServers);               // my own registrations
/// client.updatePipelines(did, bridges, sockets);  // from dial/accept
/// client.sendData(data, receiver: peer);          // reliable DATA
/// client.sendFrame(frame, receiver: peer);        // VoMP media frame
/// client.sendPacket(packet, receiver: peer, command: 0x12345678);  // custom
/// client.removePipelines(did);                    // on hangup
/// client.close();                                 // on shutdown
/// ```
///
/// See vomp/client.md for the design; the app drives everything with
/// 'updatePipelines' (inbound port info) and 'send' (outbound data).
class MagpieClient with Logging implements MagpieDelegate {
  MagpieClient._internal();
  static final MagpieClient _instance = MagpieClient._internal();
  static MagpieClient get instance => _instance;
  factory MagpieClient() => _instance;

  /// reserved command value 'VoMP' (Voice over Magpie Protocol)
  static const int commandVoMP = 0x566F4D50;

  /// Whether [command] is a system command consumed by the link/pipe
  /// layers (see [onPacketReceived]): the link observes every inbound
  /// packet to the delegate first, but only reliable DATA (C=0) and
  /// custom-command packets (C=1, e.g. 'VoMP') reach the app.
  static bool _isSystemCommand(int command) {
    switch (command) {
      case Command.SYN: // handshake
      case Command.SYN_ACK:
      case Command.ACK:
      case Command.FAIL: // results
      case Command.DONE:
      case Command.ACPT: // permits
      case Command.DENY:
      case Command.PING: // heartbeat / probe
      case Command.PONG:
      case Command.FIN: // shutdown
      case Command.FIN_ACK:
      case Command.NOOP:
      case Command.COPY: // reliable-layer ack
        return true;
      default:
        return false;
    }
  }

  MagpieClientDelegate? delegate;

  /// tick period of the internal driver
  static const Duration tickInterval = Duration(seconds: 10);

  MagHub? _hub;
  final Enigma _enigma = Enigma();
  final Config _config = Config();
  PipeManager? _manager;
  Timer? _timer;
  Future<void>? _binding;

  /// per did reliable-data serial number
  final Map<ID, int> _sn = {};

  /// link type of the last inbound custom-command packet (the peer's
  /// send path): true = direct, false = bridged
  bool? _inboundDirect;

  /// cumulative wire bytes sent/received over every link since the
  /// binding (for the call bandwidth display)
  int _upBytes = 0;
  int _downBytes = 0;

  String? _lastSelf;

  /// whether bind() has bound the shared socket
  bool get ready => _hub != null;

  /// Bind the shared UDP socket and create the internal hub, then start
  /// the internal ~10s ticker (cancelled by [close]) - the app never
  /// drives the links itself. Idempotent: repeated/concurrent calls
  /// share the first binding.
  ///
  /// Set the app secrets pre-shared with the bridges (for the encrypted
  /// handshake) via [updateSecrets]. After bind, call [connectBridges]
  /// to register on my own bridges, so that myBridges / mySockets carry
  /// the port info for the first dial.
  Future<void> bind({InternetAddress? host, int port = 0}) async {
    if (_hub != null) {
      return; // already bound
    }
    _binding ??= _bind(host: host, port: port)
        .whenComplete(() => _binding = null);
    try {
      await _binding;
    } catch (e, st) {
      logError('failed to bind ($host, $port) for magpie client: $e, $st');
    }
  }

  Future<void> _bind({InternetAddress? host, int port = 0}) async {
    final hub = await MagHub.create(
      host: host,
      port: port,
      enigma: _enigma,
      config: _config,
      delegate: this,
    );
    _hub = hub;
    _manager = PipeManager(hub: hub, onPipelinesReady: (did) {
      delegate?.onPipelinesReady(did);
    });
    _timer = Timer.periodic(tickInterval, (_) => keepAlive());
  }

  /// Disconnect every link and close the shared socket.
  void close() {
    _timer?.cancel();
    _timer = null;
    _hub?.close();
    _hub = null;
    _manager?.close();
    _manager = null;
    _sn.clear();
    _inboundDirect = null;
    _upBytes = 0;
    _downBytes = 0;
    _lastSelf = null;
  }

  /// Set the named keys pre-shared with the bridges (for the encrypted
  /// handshake). Items with an empty key are skipped. Safe before
  /// [bind] or anytime later: the hub shares this Enigma, so every
  /// handshake dialed afterwards carries the fresh keys.
  void updateSecrets(List<EnigmaItem> enigmaItems) {
    final enigmaSecrets = <String, Uint8List>{};
    for (var item in enigmaItems) {
      Uint8List? ikm = item.secret;
      if (ikm != null && ikm.isNotEmpty) {
        enigmaSecrets[item.index] = ikm;
      }
    }
    _enigma.updateSecrets(enigmaSecrets);
  }

  //
  //  Pipelines
  //

  /// Register on my own bridge servers (from the config file): dial
  /// each of them so that myBridges / mySockets carry the port info for
  /// the first dial. Idempotent per endpoint. Call after [bind].
  void connectBridges(List bridges) {
    List<SocketAddress> servers = [];
    for (var item in bridges) {
      if (item is SocketAddress) {
        servers.add(item);
        continue;
      } else if (item is! Map) {
        assert(item == null, 'magpie bridge error: $item');
        continue;
      }
      var host = item['host'];
      var port = item['port'];
      if (host != null && port != null) {
        servers.add((host: InternetAddress(host.toString()), port: port));
      }
    }
    logWarning('trying to connect bridges: $bridges');
    _manager?.connectBridges(servers);
  }

  /// Register the peer's port info (from its 'dial'/'accept' signaling):
  /// dial every bridge server and every direct endpoint listed there.
  /// Both lists are deduped by endpoint; existing links are reused.
  /// Runs an immediate tick afterwards, so the handshakes get their
  /// first retransmission check and the bridge permits go out as soon
  /// as the handshakes complete - no need to wait the next period.
  void updatePipelines(ID did, Iterable<BridgeEntry> bridges, Iterable<SocketEntry> sockets) {
    _manager?.updatePipelines(did, bridges, sockets);
    keepAlive();
  }

  /// Tear down everything registered for the peer (call on hangup):
  /// direct links with no other owner are disconnected, bridge pipes
  /// are removed by the peer's bid ('DENY'), but the bridge links stay
  /// (they are shared: my own registrations and other peers may live on
  /// the same server).
  void removePipelines(ID did) {
    _manager?.removePipelines(did);
  }

  /// My own registration on every ready bridge: entries of my
  /// 'magpie-bridges' list for dial/accept signaling.
  List<BridgeEntry> get myBridges => _manager?.myBridges ?? const [];

  /// The NAT mappings my bridges observed: entries of my 'magpie-sockets'
  /// list for dial/accept signaling (deduped, all-cone NAT shares one).
  List<SocketEntry> get mySockets => _manager?.mySockets ?? const [];

  /// Whether the fastest ready pipe to the receiver runs over a direct
  /// link: true = direct, false = bridged (relayed), null = no pipe is
  /// ready. The path may change mid-call (fallback re-ranking), so poll
  /// it for display instead of caching.
  bool? isDirect(ID receiver) {
    final pipe = _manager?.fastestPipe(receiver);
    if (pipe == null) {
      return null;
    }
    return pipe is! BridgePipe;
  }

  /// Link type of the last inbound custom-command packet: the path the
  /// peer sends on (true = direct, false = bridged, null = nothing
  /// received yet). System commands (probes/heartbeats) are not counted
  /// - they may mirror my own path, not the peer's choice.
  bool? get inboundDirect => _inboundDirect;

  /// Cumulative wire bytes sent over every link since the binding.
  int get uplinkBytes => _upBytes;

  /// Cumulative wire bytes received over every link since the binding.
  int get downlinkBytes => _downBytes;

  //
  //  Sending
  //

  /// Send a reliable DATA packet to the receiver via the fastest pipe
  /// (sn auto-numbered per receiver unless given). Returns false when no
  /// pipe is ready; for media frames use [sendFrame], for other custom
  /// commands [sendPacket].
  bool sendData(Uint8List payload, {
    int? sn,
    required ID receiver,
  }) {
    final pipe = _manager?.fastestPipe(receiver);
    if (pipe == null) {
      return false;
    }
    return pipe.sendData(payload, sn: sn ?? _nextSn(receiver));
  }

  /// Send a VoMP media frame (voice/video) to the receiver via the
  /// fastest pipe: fire-and-forget with the reserved 'VoMP' command - a
  /// shorthand for [sendPacket] with [commandVoMP].
  /// Returns false when no pipe is ready.
  bool sendFrame(Uint8List frame, {required ID receiver}) {
    return sendPacket(frame, command: commandVoMP, receiver: receiver);
  }

  /// Build a custom-command packet (C=1, D=0 fire-and-forget, e.g.
  /// 'VoMP') for the peer and send it via the fastest pipe: the packet
  /// must be built per pipe type (a bridge pipe carries the receiver's
  /// bid as target, mine as source), hence no pre-built packet here.
  /// Returns false when no pipe is ready.
  bool sendPacket(Uint8List payload, {
    required int command,
    required ID receiver,
  }) {
    final pipe = _manager?.fastestPipe(receiver);
    if (pipe == null) {
      return false;
    }
    Magpie packet;
    if (pipe is BridgePipe) {
      final bp = pipe;
      packet = BridgePacket.create(
        ack: 0, target: bp.target, source: bp.source,
        sn: 0, index: 0, count: 1,
        command: command, payload: payload,
      );
    } else {
      packet = DirectPacket.create(
        ack: 0, sn: 0, index: 0, count: 1,
        command: command, payload: payload,
      );
    }
    return pipe.sendPacket(packet);
  }

  //
  //  Driving
  //

  /// Run the links: the internal ticker calls me every [tickInterval] -
  /// the speed probes, heartbeats, permit re-issue and direct re-dials
  /// all hang off this. Safe to call anytime (e.g. right after
  /// [updatePipelines] for an immediate round): every step inside is
  /// rate-limited by wall-clock timestamps.
  void keepAlive() {
    final manager = _manager;
    if (manager == null) {
      return;
    }
    final now = DateTime.now();
    // the probe PINGs go out first: they refresh the links' last-send
    // time, so hub.keepAlive adds no duplicate PINGs
    manager.tick(now);
    _hub?.keepAlive(now);
    _checkSelf();
  }

  /// Notify the app when my own registration info has changed.
  void _checkSelf() {
    final snapshot = _selfSnapshot();
    if (_lastSelf != null && _lastSelf == snapshot) {
      return;
    }
    _lastSelf = snapshot;
    delegate?.onSelfUpdated();
  }

  String _selfSnapshot() {
    final bids = myBridges
        .map((e) => '${e.host.address}:${e.port}:${e.bid}').join(',');
    final sockets = mySockets
        .map((e) => '${e.host.address}:${e.port}').join(',');
    return '$bids|$sockets';
  }

  //
  //   MagpieDelegate (link layer observer)
  //

  @override
  void onPacketReceived(Packet packet, MagPipe? pipe, MagLink link) {
    _downBytes += packet.pack().length;
    // the PONG closes the manager's PING probe (rtt), then the packet
    // resolves back to its owner did(s)
    final senders = _manager?.onPacketReceived(packet, link);
    if (senders == null || senders.isEmpty) {
      return; // stale (bid migrated), foreign, or server-origin packet
    }
    if (_isSystemCommand(packet.command)) {
      return; // link/pipe control: consumed internally already
    }
    _inboundDirect = link is! BridgeLink;
    for (var sender in senders) {
      delegate?.onPacketReceived(packet, pipe, link, sender: sender);
    }
  }

  @override
  void onPacketSent(Magpie packet, MagPipe? pipe, MagLink link) {
    _upBytes += packet.pack().length;
  }

  @override
  void onPacketFailed(Magpie packet, MagPipe? pipe, MagLink link) {
    // count only; the pipe ranking drops failing paths via rtt anyway
  }

  @override
  void onUnknownPeer(Uint8List data, SocketAddress remote) {
    // most likely a receiver's direct-connect 'SYN?': complete the
    // handshake when the endpoint belongs to a registered peer, else
    // ignore
    _manager?.onUnknownPeer(remote);
  }

  //
  //   Internals
  //

  int _nextSn(ID receiver) {
    final value = (_sn[receiver] ?? 0) + 1;
    _sn[receiver] = value;
    return value;
  }
}
