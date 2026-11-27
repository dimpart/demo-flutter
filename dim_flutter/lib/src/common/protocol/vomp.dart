/* license: https://mit-license.org
 *
 *  DIM-SDK : Decentralized Instant Messaging Software Development Kit
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
import 'package:dim_client/common.dart';

import 'app.dart';

/// Voice call record: an AppContent (type 0xA0) carrying only the display
/// text, so the chat box can render it with a phone icon to distinguish it
/// from normal text messages.
class CallRecordContent extends AppOnlyContent {
  CallRecordContent(super.dict);

  /// The 'app' field is fixed to [VompContent.APP] - the record belongs to
  /// the same telecon application as the signaling.
  CallRecordContent.fromText({required String text})
      : super.from(app: VompContent.APP) {
    this['text'] = text;
  }

}

/// VoMP signaling message: a DIMP CustomizedContent with the fixed envelope
/// 'app' = 'chat.dim.telecon', 'mod' = 'vomp' and the 'act' of one of the
/// ACT_* constants (vomp/signaling.md).
///
/// Build me with the factory constructors ([VompContent.dial], [VompContent.accept],
/// [VompContent.start], ...); wrap inbound content with [parse] - null when it is
/// not ours, never throws. Packing the dict into a DIMP ReliableMessage
/// (encrypt + sign) and delivering it via the Station stays the upper layer's job.
class VompContent extends AppCustomizedContent {
  VompContent(super.dict);

  // ignore_for_file: constant_identifier_names
  static const String APP = 'chat.dim.telecon';
  static const String MOD = 'vomp';

  /// VoMP act names (vomp/signaling.md).
  static const String ACT_DIAL   = 'dial';
  static const String ACT_ACCEPT = 'accept';
  static const String ACT_START  = 'start';
  static const String ACT_REJECT = 'reject';
  static const String ACT_CANCEL = 'cancel';
  static const String ACT_BYE    = 'bye';
  static const String ACT_BUSY   = 'busy';
  static const String ACT_UPDATE = 'update';

  static const Set<String> ACT_ALL = {
    ACT_DIAL, ACT_ACCEPT, ACT_START, ACT_REJECT, ACT_CANCEL,
    ACT_BYE, ACT_BUSY, ACT_UPDATE,
  };

  VompContent.create(String act, ID meeting)
      : super.from(app: APP, mod: MOD, act: act) {
    this['meeting'] = meeting.toString();
  }

  //
  //  Factories
  //

  /// 'dial' - the caller rings the callee: the meeting ID (a temporary
  /// Polylogue ID derived from the caller's meta.seed = 'call-xxxx'), the two
  /// bare member IDs in order [initiator, receiver], the caller's own
  /// port info, and the PROPOSED audio params (local capability probe result;
  /// signaling.md section 1).
  factory VompContent.dial(ID meeting, {
    required List<ID> members,
    required List<Map> bridges,
    required List<Map> sockets,
    required Map media,
  }) {
    final content = VompContent.create(ACT_DIAL, meeting);
    content['members'] = ID.revert(members);
    content['magpie-bridges'] = bridges;
    content['magpie-sockets'] = sockets;
    content['media'] = media;
    return content;
  }

  /// 'accept' - the callee answers with its own port info and the CONFIRMED
  /// audio params: the dial proposal intersected with the local capability
  /// (either side without Opus => 'pcm16'); both sides follow it
  /// (signaling.md section 2).
  factory VompContent.accept(ID meeting, {
    required List<Map> bridges,
    required List<Map> sockets,
    required Map media,
  }) {
    final content = VompContent.create(ACT_ACCEPT, meeting);
    content['magpie-bridges'] = bridges;
    content['magpie-sockets'] = sockets;
    content['media'] = media;
    return content;
  }

  /// 'start' - the caller receives 'accept' and starts the meeting: the
  /// numbered participants (both with terminal - the number is the media nonce's
  /// senderId), the generated meeting key (32 bytes) and the agreed initial
  /// media params {'codec', 'rate', 'channels'} (section 3).
  factory VompContent.start(ID meeting, {
    required Map participants,
    required TransportableData meetingKey,
    required Map media,
  }) {
    final content = VompContent.create(ACT_START, meeting);
    content['participants'] = participants;
    content['meeting-key'] = meetingKey.serialize();
    content['media'] = media;
    return content;
  }

  /// 'reject' - the callee declines the call (section 4).
  factory VompContent.reject(ID meeting) =>
      VompContent.create(ACT_REJECT, meeting);

  /// 'cancel' - the caller aborts a still-ringing call (section 5).
  factory VompContent.cancel(ID meeting) =>
      VompContent.create(ACT_CANCEL, meeting);

  /// 'bye' - hang up, with the sender-measured talk seconds ('accept' -> 'bye')
  /// so both chat records show the same duration (section 6).
  factory VompContent.bye(ID meeting, {required num duration}) {
    final content = VompContent.create(ACT_BYE, meeting);
    content['duration'] = duration;
    return content;
  }

  /// 'busy' - auto reply when the callee is waiting for or in another call
  /// (section 7).
  factory VompContent.busy(ID meeting) =>
      VompContent.create(ACT_BUSY, meeting);

  /// 'update' - mid-call push of my fresh port info after my own re-handshake
  /// (onSelfUpdated, section 8).
  factory VompContent.update(ID meeting, {
    required List<Map> bridges,
    required List<Map> sockets,
  }) {
    final content = VompContent.create(ACT_UPDATE, meeting);
    content['magpie-bridges'] = bridges;
    content['magpie-sockets'] = sockets;
    return content;
  }

  //
  //  Parsing
  //

  /// Wrap inbound content as a VoMP signaling message: null when it is not a
  /// customized content of ours (wrong app/mod, unknown act, no meeting) -
  /// never throws.
  static VompContent? parse(Content content) {
    if (content is VompContent) {
      return content;
    }
    if (content.getString('app') != APP || content.getString('mod') != MOD) {
      return null;
    }
    final action = content.getString('act');
    if (action == null || !ACT_ALL.contains(action)) {
      return null; // unknown act
    }
    if (content.getString('meeting') == null) {
      return null; // 'meeting' is required for every act
    }
    return VompContent(content.toMap());
  }

  //
  //  Getters
  //

  /// the meeting ID (a temporary Polylogue ID)
  ID? get meeting => ID.parse(getString('meeting'));

  /// 'dial': the two bare member IDs [initiator, receiver]
  List<ID>? get members {
    final array = this['members'];
    if (array is! List) {
      assert(array == null, 'members error: $array');
      return null;
    }
    return ID.convert(array);
  }

  /// 'start': the numbered participants (device IDs with terminal) - the
  /// number is the media nonce's senderId
  Map? get participants => this['participants'];

  /// 'magpie-bridges': where the peer is registered
  List<Map>? get magpieBridges {
    final array = this['magpie-bridges'];
    if (array is! List) {
      assert(array == null, 'magpie-bridges error: $array');
      return null;
    }
    // JSON round-trip turns 'List<Map>' into 'List<dynamic>'
    return array.whereType<Map>().toList();
  }

  /// 'magpie-sockets': the peer's NAT mappings
  List<Map>? get magpieSockets {
    final array = this['magpie-sockets'];
    if (array is! List) {
      assert(array == null, 'magpie-sockets error: $array');
      return null;
    }
    return array.whereType<Map>().toList();
  }

  /// 'start': the generated meeting key (32 bytes)
  TransportableData? get meetingKey {
    var ted = _meetingKey;
    if (ted == null) {
      ted = TransportableData.parse(this['meeting-key']);
      _meetingKey = ted;
    }
    return ted;
  }
  TransportableData? _meetingKey;

  /// 'start': optional initial media params (codec / rate / channels)
  Map? get media => this['media'];

  /// 'bye': the sender-measured talk seconds
  double? get duration => getDouble('duration');

}
