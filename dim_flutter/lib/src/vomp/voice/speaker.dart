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
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

import '../payload/format.dart';

/// Hands exactly one 20ms frame of s16le samples to the native mixer.
typedef VoiceOutput = void Function(Uint8List pcm);

/// Ready-to-use speaker player: queues decoded frames in a jitter buffer
/// and plays them out at a steady 20ms pace (16kHz mono by default).
///
/// Before the first drain it waits until the buffer reaches [startThreshold]
/// frames (pre-buffering, ~60ms) to mask the network jitter; when the buffer
/// runs dry it falls back to pre-buffering. On overflow the oldest frames
/// are dropped, so the latency never exceeds [maxDepth].
///
/// ```dart
/// var player = PcmSpeaker();
/// await player.start();
/// // for every payload received from the network:
/// var frame = codec.decodeFrame(payload);
/// if (frame != null) player.push(frame.pcm);
/// // ...
/// await player.stop();
/// ```
class PcmSpeaker {
  PcmSpeaker({int? sampleRate, int? channels, VoiceOutput? output})
      : sampleRate = sampleRate ?? PayloadFormat.defaultSampleRate,
        channels = channels ?? PayloadFormat.defaultChannels,
        _output = output ?? _pluginOutput;

  /// playback profile (negotiated with the peer via signaling)
  final int sampleRate;
  final int channels;
  final VoiceOutput _output;

  /// frames to queue before the first drain (pre-buffering)
  static const int startThreshold = 3;

  /// hard limit of the jitter buffer (in frames); the oldest frames are
  /// dropped beyond it (12 * 20ms = 240ms)
  static const int maxDepth = 12;

  final Queue<Uint8List> _jitter = Queue<Uint8List>();
  Timer? _ticker;
  bool _playing = false;
  bool _running = false;

  /// whether the playback end is running
  bool get running => _running;

  /// frames currently queued (backlog of the jitter buffer)
  int get backlog => _jitter.length;

  /// Bring up the playback end and the 20ms ticker.
  Future<bool> start() async {
    if (_running) {
      return true;
    }
    if (identical(_output, _pluginOutput)) {
      try {
        await FlutterPcmSound.setLogLevel(LogLevel.none);
        await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: channels);
      } catch (error) {
        return false; // speaker unavailable
      }
    }
    _ticker = Timer.periodic(_pace, (_) => _drain());
    _running = true;
    return true;
  }

  /// Shut the playback end down (idempotent).
  Future<void> stop() async {
    if (!_running) {
      return;
    }
    _running = false;
    _ticker?.cancel();
    _ticker = null;
    _playing = false;
    _jitter.clear();
    if (identical(_output, _pluginOutput)) {
      try {
        await FlutterPcmSound.release();
      } catch (error) {
        // already released
      }
    }
  }

  /// Queue one decoded frame; frames of another profile are dropped
  /// (the profile is negotiated once per call).
  void push(Uint8List pcm) {
    if (!_running) {
      return; // not started yet, drop it
    }
    if (pcm.length != PayloadFormat.pcmFrameBytes(sampleRate, channels)) {
      return; // profile mismatch
    }
    _jitter.add(pcm);
    while (_jitter.length > maxDepth) {
      _jitter.removeFirst(); // too late to play
    }
  }

  /// 20ms pace derived from the playback profile
  Duration get _pace => const Duration(milliseconds: PayloadFormat.frameMillis);

  /// Feed one frame per tick to the native end - usually exactly one;
  /// none while pre-buffering.
  void _drain() {
    if (!_playing) {
      if (_jitter.length < startThreshold) {
        return; // keep pre-buffering
      }
      _playing = true;
    }
    if (_jitter.isEmpty) {
      _playing = false; // buffer ran dry, fall back to pre-buffering
      return;
    }
    _output(_jitter.removeFirst());
  }

  /// default sink: the `flutter_pcm_sound` plugin (keeps its own native
  /// queue, so the fed frames are played gapless)
  static void _pluginOutput(Uint8List pcm) {
    // the plugin reads the whole underlying buffer, so an independent
    // exact-size copy is needed
    final copy = Uint8List.fromList(pcm);
    FlutterPcmSound.feed(PcmArrayInt16(bytes: copy.buffer.asByteData()));
  }
}
