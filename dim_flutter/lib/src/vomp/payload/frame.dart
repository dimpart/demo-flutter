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
import 'dart:typed_data';

import 'package:lnc/log.dart';
import 'package:opus_codec/opus_flutter.dart' show load;
import 'package:opus_codec_dart/opus_codec_dart.dart' as opus;

import 'format.dart';

/// Audio frame: PCM data + stream-level parameters (shared by both
/// directions).
///
/// On the sending way the Recorder fills [pcm] / [sampleRate] / [channels];
/// on the receiving way the codec restores every field from the AAD and
/// the nonce (see vomp/protocol.md section 2).
class VoiceFrame {
  /// s16le samples, exactly one 20ms frame; empty for a KEEPALIVE.
  final Uint8List pcm;

  /// e.g. 16000 (Opus WB, the v1 default)
  final int sampleRate;

  /// 1 = mono / 2 = stereo
  final int channels;

  /// restored from the nonce, 1 = initiator / 2 = receiver (RX only)
  final int senderId;

  /// restored from the nonce timestamp (RX only)
  final DateTime time;

  VoiceFrame({
    required this.pcm,
    required this.sampleRate,
    required this.channels,
    required this.senderId,
    required this.time,
  });

  @override
  String toString() =>
      'VoiceFrame{pcm: ${pcm.length}B, sampleRate: $sampleRate,'
      ' channels: $channels, senderId: $senderId, time: $time}';
}

/// The Opus coder pair used by the payload codec: one instance per AAD
/// config (Fs = 4000 x rate, channels), created through a factory so the
/// tests can inject a fake instead of the native libopus.
abstract interface class OpusGateway {
  /// Encode one 20ms frame of s16le samples into an Opus packet;
  /// null on failure (oversized output, native error, ...).
  Uint8List? encode(Int16List pcm);

  /// Decode one Opus packet into s16le samples; null on failure.
  Int16List? decode(Uint8List packet);

  /// Release the native handles (idempotent).
  void destroy();
}

/// Creates the gateways for an AAD config; returns null when the native
/// library is unavailable (the codec then falls back to PCM16 pass-through).
typedef OpusGatewayFactory = OpusGateway? Function({
  required int sampleRate,
  required int channels,
});

/// Whether the FFI bindings are initialized already.
bool _opusInitialized = false;
Future<bool>? _opusLoading;

/// Load the native libopus and initialize the FFI bindings: the coders
/// cannot be created before that ('late' global throws otherwise, and a
/// silent catch turns that into 'no Opus' forever). Idempotent, retriable
/// on failure. Returns whether the library is usable.
Future<bool> loadOpusLibrary() {
  if (_opusInitialized) {
    return Future.value(true);
  }
  return _opusLoading ??= _loadOpusLibrary();
}

Future<bool> _loadOpusLibrary() async {
  try {
    opus.initOpus(await load());
    _opusInitialized = true;
    Log.info('[opus] native library loaded');
    return true;
  } catch (error) {
    Log.warning('[opus] failed to load opus library: $error');
    return false;
  } finally {
    _opusLoading = null; // allow a retry on the next call
  }
}

OpusGateway? createNativeOpusGateway({required int sampleRate, required int channels}) {
  try {
    final encoder = opus.SimpleOpusEncoder(
      sampleRate: sampleRate,
      channels: channels,
      application: opus.Application.restrictedLowdelay,
    );
    final decoder = opus.SimpleOpusDecoder(
      sampleRate: sampleRate,
      channels: channels,
    );
    return _SimpleOpusGateway(encoder, decoder);
  } catch (error) {
    return null;
  }
}

class _SimpleOpusGateway implements OpusGateway {
  _SimpleOpusGateway(this._encoder, this._decoder);

  final opus.SimpleOpusEncoder _encoder;
  final opus.SimpleOpusDecoder _decoder;

  @override
  Uint8List? encode(Int16List pcm) {
    try {
      return _encoder.encode(input: pcm, maxOutputSizeBytes: PayloadFormat.maxCiphertextLength);
    } catch (error) {
      return null; // oversized packet or native error
    }
  }

  @override
  Int16List? decode(Uint8List packet) {
    try {
      return _decoder.decode(input: packet);
    } catch (error) {
      return null;
    }
  }

  @override
  void destroy() {
    _encoder.destroy();
    _decoder.destroy();
  }
}
