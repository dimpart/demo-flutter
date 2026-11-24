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
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
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
import 'dart:typed_data';

import 'package:dim_client/common.dart' show Base64;
import 'package:dim_client/common.dart' show ID;
import 'package:dim_client/common.dart' show Content, AppCustomizedContent;

import 'pipeline.dart';

/// VoMP act names (vomp/signaling.md).
abstract class VompAct {
  static const String dial = 'dial';
  static const String accept = 'accept';
  static const String start = 'start';
  static const String reject = 'reject';
  static const String cancel = 'cancel';
  static const String bye = 'bye';
  static const String busy = 'busy';
  static const String update = 'update';

  static const Set<String> all = {
    dial, accept, start, reject, cancel, bye, busy, update,
  };
}

/// VoMP signaling message: a DIMP CustomizedContent with the fixed envelope
/// 'app' = 'chat.dim.telecon', 'mod' = 'vomp' and the 'act' of one of the
/// [VompAct]s (vomp/signaling.md).
///
/// Build me with the factory constructors ([VompContent.dial], [VompContent.accept],
/// [VompContent.start], ...); wrap inbound content with [parse] - null when it is
/// not ours, never throws. Packing the dict into a DIMP ReliableMessage
/// (encrypt + sign) and delivering it via the Station stays the upper layer's job.
class VompContent extends AppCustomizedContent {
  VompContent(super.dict);

  /// envelope
  static const String app = 'chat.dim.telecon';
  static const String mod = 'vomp';

  VompContent._from(String act, ID meeting)
      : super.from(app: app, mod: mod, act: act) {
    this['meeting'] = meeting.toString();
  }

  //
  //  Builders
  //

  /// 'dial' - the caller rings the callee: the meeting ID (a temporary
  /// Polylogue ID derived from the caller's meta.seed = 'call-xxxx'), the two
  /// bare member IDs in order [initiator, receiver], and the caller's own
  /// port info (signaling.md section 1).
  factory VompContent.dial({
    required ID meeting,
    required List<ID> members,
    required List<BridgeEntry> bridges,
    required List<SocketEntry> sockets,
  }) {
    final content = VompContent._from(VompAct.dial, meeting);
    content['members'] = members.map((id) => id.toString()).toList();
    content['magpie-bridges'] = _bridges(bridges);
    content['magpie-sockets'] = _sockets(sockets);
    return content;
  }

  /// 'accept' - the callee answers with its own port info (section 2).
  factory VompContent.accept({
    required ID meeting,
    required List<BridgeEntry> bridges,
    required List<SocketEntry> sockets,
  }) {
    final content = VompContent._from(VompAct.accept, meeting);
    content['magpie-bridges'] = _bridges(bridges);
    content['magpie-sockets'] = _sockets(sockets);
    return content;
  }

  /// 'start' - the caller receives 'accept' and starts the meeting: the
  /// numbered participants (both with terminal - the number is the media nonce's
  /// senderId), the generated meeting key (32 bytes) and the optional initial
  /// media params {'codec', 'rate', 'channels'} (section 3).
  factory VompContent.start({
    required ID meeting,
    required Map<String, ID> participants,
    required Uint8List meetingKey,
    Map? media,
  }) {
    final content = VompContent._from(VompAct.start, meeting);
    content['participants'] = participants.map((key, id) => MapEntry(key, id.toString()));
    content['meeting-key'] = Base64.encode(meetingKey);
    if (media != null) {
      content['media'] = media;
    }
    return content;
  }

  /// 'reject' - the callee declines the call (section 4).
  factory VompContent.reject({required ID meeting}) =>
      VompContent._from(VompAct.reject, meeting);

  /// 'cancel' - the caller aborts a still-ringing call (section 5).
  factory VompContent.cancel({required ID meeting}) =>
      VompContent._from(VompAct.cancel, meeting);

  /// 'bye' - hang up, with the sender-measured talk seconds ('accept' -> 'bye')
  /// so both chat records show the same duration (section 6).
  factory VompContent.bye({required ID meeting, required num duration}) {
    final content = VompContent._from(VompAct.bye, meeting);
    content['duration'] = duration;
    return content;
  }

  /// 'busy' - auto reply when the callee is waiting for or in another call
  /// (section 7).
  factory VompContent.busy({required ID meeting}) =>
      VompContent._from(VompAct.busy, meeting);

  /// 'update' - mid-call push of my fresh port info after my own re-handshake
  /// (onSelfUpdated, section 8).
  factory VompContent.update({
    required ID meeting,
    required List<BridgeEntry> bridges,
    required List<SocketEntry> sockets,
  }) {
    final content = VompContent._from(VompAct.update, meeting);
    content['magpie-bridges'] = _bridges(bridges);
    content['magpie-sockets'] = _sockets(sockets);
    return content;
  }

  //
  //  Parsing
  //

  /// Wrap inbound content as a VoMP signaling message: null when it is not a
  /// customized content of ours (wrong app/mod, unknown act, no meeting) -
  /// never throws.
  static VompContent? parse(Content content) {
    if (content.getString('app') != app || content.getString('mod') != mod) {
      return null;
    }
    final action = content.getString('act');
    if (action == null || !VompAct.all.contains(action)) {
      return null; // unknown act
    }
    if (content.getString('meeting') == null) {
      return null; // 'meeting' is required for every act
    }
    return VompContent(content);
  }

  //
  //  Getters
  //

  /// act name
  String get act => action;

  /// the meeting ID (a temporary Polylogue ID)
  ID? get meeting => ID.parse(getString('meeting'));

  /// 'dial': the two bare member IDs [initiator, receiver]
  List<ID>? get members {
    final array = this['members'];
    if (array is! List) {
      return null;
    }
    return ID.convert(array);
  }

  /// 'start': the numbered participants (device IDs with terminal) - the
  /// number is the media nonce's senderId
  Map<String, ID>? get participants {
    final info = this['participants'];
    if (info is! Map) {
      return null;
    }
    final out = <String, ID>{};
    info.forEach((key, value) {
      final id = ID.parse(value);
      if (id != null) {
        out['$key'] = id;
      }
    });
    return out;
  }

  /// 'magpie-bridges': where the peer is registered
  List<BridgeEntry> get magpieBridges =>
      _parseList(this['magpie-bridges'], BridgeEntry.parse);

  /// 'magpie-sockets': the peer's NAT mappings
  List<SocketEntry> get magpieSockets =>
      _parseList(this['magpie-sockets'], SocketEntry.parse);

  /// 'start': the generated meeting key (32 bytes)
  Uint8List? get meetingKey {
    final string = getString('meeting-key');
    return string == null ? null : Base64.decode(string);
  }

  /// 'start': optional initial media params (codec / rate / channels)
  Map? get media => this['media'] as Map?;

  /// 'bye': the sender-measured talk seconds
  num? get duration => this['duration'] as num?;

  static List<T> _parseList<T>(dynamic raw, T? Function(Object?) factory) {
    final out = <T>[];
    if (raw is List) {
      for (var item in raw) {
        final entry = factory(item);
        if (entry != null) {
          out.add(entry);
        }
      }
    }
    return out;
  }

  static List<Map> _bridges(List<BridgeEntry> bridges) =>
      bridges.map((entry) => entry.toJson()).toList();

  static List<Map> _sockets(List<SocketEntry> sockets) =>
      sockets.map((entry) => entry.toJson()).toList();
}
