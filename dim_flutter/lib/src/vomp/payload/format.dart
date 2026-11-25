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

/// Wire format of the VoMP payload (protocol.md section 2): the constants
/// and the byte-level builders shared by both directions of
/// [PayloadCodec].
///
/// Every VoMP payload is an encrypted envelope:
///
/// ```
/// {4B AAD}{12B nonce}{ciphertext}{16B tag}
/// ```
abstract final class PayloadFormat {
  //
  //  AAD fields
  //

  /// mediaType in the AAD: 'A' = audio ('V' = video is reserved)
  static const int mediaTypeAudio = 0x41;

  /// codec in the AAD: 'O' = Opus
  static const int codecOpus = 0x4F;

  /// codec in the AAD: 'P' = PCM16 pass-through
  static const int codecPcm = 0x50;

  /// cipher in the AAD: 'E' = AES-256-GCM
  static const int cipherAes256Gcm = 0x45;

  //
  //  Envelope sizes
  //

  /// {4B AAD}{12B nonce}{16B tag} - an empty ciphertext is a KEEPALIVE.
  static const int minPayloadLength = 32;

  /// ciphertext <= 1024 - 32
  static const int maxCiphertextLength = 992;

  //
  //  v1 default profile
  //

  /// 16 kHz mono, 20ms frames, restricted low delay
  static const int defaultSampleRate = 16000;
  static const int defaultChannels = 1;
  static const int frameMillis = 20;

  //
  //  Byte-level builders
  //

  /// {mediaType}{codec}{cipher}{rsv 2b | ch 2b | rate 4b}, big-endian bits
  static Uint8List buildAad({required int codec, required int rate, required int channels}) {
    final category = channels - 1; // 1 -> 0 (mono), 2 -> 1 (stereo)
    final aad = Uint8List(4);
    aad[0] = mediaTypeAudio;
    aad[1] = codec;
    aad[2] = cipherAes256Gcm;
    aad[3] = (category << 4) | (rate & 0x0F);
    return aad;
  }

  /// {senderId(4B) || timestamp(4B) || counter(4B)}, big-endian
  static Uint8List buildNonce({
    required int senderId,
    required int timestamp,
    required int counter,
  }) {
    final nonce = Uint8List(12);
    final view = ByteData.sublistView(nonce);
    view.setUint32(0, senderId, Endian.big);
    view.setUint32(4, timestamp, Endian.big);
    view.setUint32(8, counter, Endian.big);
    return nonce;
  }

  /// Opus only supports these sample-rate buckets (protocol.md 2.1)
  static bool validRate(int rate) {
    return rate == 2 || rate == 3 || rate == 4 || rate == 6 || rate == 12;
  }

  /// exact channel count: 1 = mono / 2 = stereo (multistream is not v1)
  static int? validChannels(int channels) {
    return (channels == 1 || channels == 2) ? channels : null;
  }

  /// byte length of one 20ms s16le frame
  static int pcmFrameBytes(int sampleRate, int channels) {
    return sampleRate * frameMillis ~/ 1000 * channels * 2;
  }

  /// the TOC config index 16..31 marks a stereo source (RFC 6716, 3.1)
  static bool tocIsStereo(int toc) {
    return (toc >> 3) >= 16;
  }

  /// s16le byte stream -> samples (the wire order is little-endian)
  static Int16List pcmToInt16(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);
    final samples = Int16List(bytes.length ~/ 2);
    for (var i = 0; i < samples.length; ++i) {
      samples[i] = view.getInt16(i * 2, Endian.little);
    }
    return samples;
  }

  /// samples -> s16le byte stream
  static Uint8List int16ToPcm(Int16List samples) {
    final bytes = Uint8List(samples.length * 2);
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < samples.length; ++i) {
      view.setInt16(i * 2, samples[i], Endian.little);
    }
    return bytes;
  }
}
