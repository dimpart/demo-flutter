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

/// Entry of the 'magpie-bridges' list: where the peer is registered.
///
/// ```json
/// {"host": "12.34.56.78", "port": 9360, "bid": 12345}
/// ```
class BridgeEntry {
  BridgeEntry({required this.host, required this.port, required this.bid});

  final InternetAddress host;
  final int port;

  /// the peer's bid on this bridge
  final int bid;

  SocketAddress get endpoint => (host: host, port: port);

  /// Parse from a map or a JSON string; returns null on malformed input
  /// (the lists come from untrusted signaling, never throw).
  static BridgeEntry? parse(Object? obj) {
    Map? info;
    if (obj is Map) {
      info = obj;
    } else if (obj is String) {
      info = JSONMap.decode(obj);
    }
    final host = InternetAddress.tryParse(info?['host'] as String? ?? '');
    final port = info?['port'];
    final bid = info?['bid'];
    if (host == null || port is! int || bid is! int ||
        port <= 0 || port > 0xFFFF || bid <= 0) {
      return null;
    }
    return BridgeEntry(host: host, port: port, bid: bid);
  }

  Map toJson() => {'host': host.address, 'port': port, 'bid': bid};

  @override
  String toString() => 'BridgeEntry{host: ${host.address}, port: $port, bid: $bid}';
}

/// Entry of the 'magpie-sockets' list: the peer's NAT mapping as observed
/// by a bridge.
///
/// ```json
/// {"host": "11.22.33.44", "port": 50000}
/// ```
class SocketEntry {
  SocketEntry({required this.host, required this.port});

  final InternetAddress host;
  final int port;

  SocketAddress get endpoint => (host: host, port: port);

  /// Parse from a map or a JSON string; returns null on malformed input
  /// (the lists come from untrusted signaling, never throw).
  static SocketEntry? parse(Object? obj) {
    Map? info;
    if (obj is Map) {
      info = obj;
    } else if (obj is String) {
      info = JSONMap.decode(obj);
    }
    final host = InternetAddress.tryParse(info?['host'] as String? ?? '');
    final port = info?['port'];
    if (host == null || port is! int || port <= 0 || port > 0xFFFF) {
      return null;
    }
    return SocketEntry(host: host, port: port);
  }

  Map toJson() => {'host': host.address, 'port': port};

  @override
  String toString() => 'SocketEntry{host: ${host.address}, port: $port}';
}

/// Pipelines of one peer, aggregated from its 'magpie-bridges' and
/// 'magpie-sockets' lists. Both lists are deduped by endpoint here
/// (signaling.md section 0: both sides must dedup).
class PeerPipelines {
  PeerPipelines(this.did);

  final ID did;

  /// keyed by the bridge server's endpoint
  final Map<SocketAddress, BridgeEntry> bridges = {};

  /// keyed by the peer's socket endpoint
  final Map<SocketAddress, SocketEntry> sockets = {};

  bool mergeBridge(BridgeEntry entry) {
    final old = bridges[entry.endpoint];
    if (old == null) {
      bridges[entry.endpoint] = entry;
      return true;
    }
    if (old.bid != entry.bid) {
      // the peer re-handshaked into a new bid on this bridge: the old
      // record is gone, only the new bid can be permitted/forwarded
      bridges[entry.endpoint] = entry;
      return true;
    }
    return false;
  }

  bool mergeSocket(SocketEntry entry) {
    final old = sockets[entry.endpoint];
    if (old == null) {
      sockets[entry.endpoint] = entry;
      return true;
    }
    return false;
  }

}
