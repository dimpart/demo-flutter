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
import 'dart:typed_data';

import 'package:record/record.dart';

import '../payload/format.dart';

/// Opens the native capture end; delivers raw s16le chunks.
typedef CaptureSource = Future<Stream<Uint8List>> Function(
    int sampleRate, int channels);

/// Ready-to-use microphone recorder: opens the mic, and emits one fixed
/// 20ms frame of s16le samples per callback (16kHz mono by default = 640B).
///
/// The slicing is event-driven: a frame is emitted the moment its samples
/// have all arrived, so the framing follows the microphone's hardware clock.
/// The DSP chain (AGC / echo cancel / NS) is switched off to keep the
/// capture latency low.
///
/// ```dart
/// var recorder = MicRecorder();
/// recorder.onFrame = (pcm) => sender.send(pcm);  // every 20ms
/// await recorder.start();  // false => no microphone permission
/// // ...
/// await recorder.stop();
/// ```
class MicRecorder {
  MicRecorder({int? sampleRate, int? channels, CaptureSource? capture})
      : sampleRate = sampleRate ?? PayloadFormat.defaultSampleRate,
        channels = channels ?? PayloadFormat.defaultChannels {
    _capture = capture ?? _recordPlugin;
  }

  /// capture profile (negotiated with the peer via signaling)
  final int sampleRate;
  final int channels;
  late final CaptureSource _capture;

  /// called with each 20ms frame of s16le samples
  void Function(Uint8List pcm)? onFrame;

  StreamSubscription<Uint8List>? _sub;
  AudioRecorder? _pluginRecorder;

  /// pending samples not yet sliced into a frame
  /// (copy the input: the platform side may reuse its callback buffer)
  final BytesBuilder _pending = BytesBuilder(copy: true);
  int _pendingBytes = 0;

  bool _recording = false;
  int _frames = 0;

  /// whether the capture end is running
  bool get recording => _recording;

  /// how many frames have been emitted since start()
  int get framesSent => _frames;

  /// Bring up the capture end.
  Future<bool> start() async {
    if (_recording) {
      return true;
    }
    Stream<Uint8List> stream;
    try {
      stream = await _capture(sampleRate, channels);
    } catch (error) {
      return false; // permission denied or device busy
    }
    _sub = stream.listen(_onChunk);
    _recording = true;
    return true;
  }

  /// Shut the capture end down (idempotent).
  Future<void> stop() async {
    if (!_recording) {
      return;
    }
    _recording = false;
    await _sub?.cancel();
    _sub = null;
    _pending.clear();
    _pendingBytes = 0;
    _frames = 0;
    await _pluginRecorder?.stop();
  }

  /// default source: the `record` plugin in pcm16 stream mode, DSP off
  Future<Stream<Uint8List>> _recordPlugin(int sampleRate, int channels) async {
    final recorder = _pluginRecorder ??= AudioRecorder();
    if (!await recorder.hasPermission()) {
      throw StateError('microphone permission denied');
    }
    return recorder.startStream(RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: sampleRate,
      numChannels: channels,
      autoGain: false,
      echoCancel: false,
      noiseSuppress: false,
    ));
  }

  /// Feed raw s16le PCM from the capture end; any size accepted - it will
  /// be buffered and sliced into exact 20ms frames.
  void _onChunk(Uint8List chunk) {
    if (onFrame == null) {
      return; // nobody is listening, drop it
    }
    _pending.add(chunk);
    _pendingBytes += chunk.length;
    _slice();
  }

  /// Emit every complete frame buffered so far - usually zero or one per
  /// callback; more after a burst from the capture end.
  void _slice() {
    final frameBytes = PayloadFormat.pcmFrameBytes(sampleRate, channels);
    if (_pendingBytes < frameBytes) {
      return;
    }
    final bytes = _pending.toBytes(); // flush the builder
    _pending.clear();
    var offset = 0;
    while (offset + frameBytes <= bytes.length) {
      onFrame?.call(Uint8List.sublistView(bytes, offset, offset + frameBytes));
      _frames += 1;
      offset += frameBytes;
    }
    _pendingBytes = bytes.length - offset;
    if (_pendingBytes > 0) {
      _pending.add(bytes.sublist(offset)); // keep the remainder
    }
  }
}
