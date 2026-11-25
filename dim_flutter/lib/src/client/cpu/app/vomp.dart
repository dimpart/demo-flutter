
import 'package:dim_client/common.dart';
import 'package:dim_client/cpu.dart';
import 'package:dim_client/ok.dart';

import '../../../common/protocol/vomp.dart';
import '../../../common/constants.dart';
import '../../../models/amanuensis.dart';

class VompHandler extends BaseCustomizedContentHandler {

  @override
  Future<List<Content>> handleAction(CustomizedContent content, ReliableMessage rMsg, Messenger messenger) async {
    final vomp = VompContent.parse(content);
    if (vomp == null) {
      // unknown act / malformed signaling
      assert(false, 'vomp command error: ${content.action}, $content, sender: ${rMsg.sender}');
      return await super.handleAction(content, rMsg, messenger);
    }
    // post notification
    var nc = NotificationCenter();
    nc.postNotification(NotificationNames.kVompCommandArrived, this, {
      'sender': rMsg.sender,
      'action': vomp.action,
      'meeting': vomp.meeting,
      'content': vomp,
    });
    // save instant message.
    await saveVompCommandAsMessage(vomp, rMsg.envelope);
    // OK
    String text = 'meeting command received.';
    return respondReceipt(text, envelope: rMsg.envelope, content: content);
  }

}

Future<bool> saveVompCommandAsMessage(VompContent content, Envelope envelope) async {
  String text;
  String template;
  Map replacements;
  final sender = envelope.sender;
  final act = content.action;
  switch (act) {
    case VompContent.ACT_DIAL:
    case VompContent.ACT_ACCEPT:
    case VompContent.ACT_START:
    case VompContent.ACT_UPDATE:
      // these acts drive the UI only, no chat record;
      // the call record is synthesized by reject/cancel/bye/busy
      return false;
    case VompContent.ACT_REJECT:
      text = 'Call rejected.';
      template = 'Call rejected by \${did}.';
      replacements = <String, Object>{
        'did': sender.toString(),
      };
      break;
    case VompContent.ACT_CANCEL:
      text = 'Call cancelled.';
      template = 'Call cancelled by \${did}.';
      replacements = <String, Object>{
        'did': sender.toString(),
      };
      break;
    case VompContent.ACT_BUSY:
      text = 'Busy.';
      template = '\${did} is busy now.';
      replacements = <String, Object>{
        'did': sender.toString(),
      };
      break;
    case VompContent.ACT_BYE:
      text = 'Call ended.';
      template = 'Call ended (\${duration}).';
      replacements = <String, Object>{
        'duration': _formatDuration(content.duration),
      };
      break;
    default:
      assert(false, 'unknown vomp action: $act, $content, sender=${envelope.sender}.');
      return false;
  }
  // create head
  final head = Envelope.create(
    sender: envelope.sender,
    receiver: envelope.receiver,
    time: envelope.time,
  );
  // create body
  final body = TextContent.create('_${text.trim()}_');
  body['format'] = 'markdown';
  body['template'] = '_${template.trim()}_';
  body['replacements'] = replacements;
  body['time'] = content['time'];
  body['sn'] = content['sn'];
  // save message
  final iMsg = InstantMessage.create(head, body);
  Amanuensis clerk = Amanuensis();
  return await clerk.saveInstantMessage(iMsg);
}

/// format talk seconds: '45s' / '1m 3s' / '1h 2m'
String _formatDuration(double? seconds) {
  if (seconds == null) {
    return '?';
  }
  final total = seconds.round();
  if (total < 60) {
    return '${total}s';
  }
  final minutes = total ~/ 60;
  if (minutes < 60) {
    final sec = total % 60;
    return sec == 0 ? '${minutes}m' : '${minutes}m ${sec}s';
  }
  final hours = minutes ~/ 60;
  final min = minutes % 60;
  return min == 0 ? '${hours}h' : '${hours}h ${min}m';
}
