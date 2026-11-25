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

import 'package:magpipe/magpipe.dart';
import 'package:opus_codec/opus_flutter.dart' show load;
import 'package:opus_codec_dart/opus_codec_dart.dart' as opus;

import 'format.dart';
import 'frame.dart';

/// VoMP payload codec: Opus coding + AES-256-GCM encryption + payload
/// assembly, between the audio ends (Recorder / Player) and the transport
/// (MagpieClient, command='VoMP').
///
/// One instance manages both directions of a 1v1 call. It is stateful:
/// it holds the direction keys (K_1 / K_2, derived via HKDF by the
/// signaling layer and passed in), the outbound frame counter (monotonic
/// within the call, never reset nor wrapped) and the decoders created per
/// AAD config. See vomp/codec.md; the wire format is vomp/protocol.md
/// section 2:
///
/// ```
/// {4B AAD}{12B nonce}{ciphertext}{16B tag}
/// ```
///
/// Usage:
/// ```
/// var codec = PayloadCodec(localId: 1, keys: {1: k1, 2: k2});
/// await codec.init();          // false => PCM16 pass-through (fuse)
/// var payload = codec.encodeFrame(frame);
/// var frame = codec.decodeFrame(payload);
/// ```
class PayloadCodec {
  PayloadCodec({
    required int localId,
    required Map<int, Uint8List> keys,
    OpusGatewayFactory? opusFactory,
  })  : _localId = localId,
        _keys = Map<int, Uint8List>.of(keys),
        _opusFactory = opusFactory ?? createNativeOpusGateway;

  final int _localId;
  final Map<int, Uint8List> _keys;
  final OpusGatewayFactory _opusFactory;

  /// outbound frame counter: monotonic, never reset nor wrapped
  int _counter = 0;

  /// whether init() has run, and whether the Opus path is usable
  bool _initialized = false;
  bool _opusReady = false;

  /// mirror policy: optimistic mirror of the peer's latest authenticated
  /// outbound codec - a peer sending PCM16 cannot decode Opus either, so we
  /// mirror it; if a future version recovers Opus mid-call, we follow it
  /// back (its KEEPALIVEs advertise the capability via the AAD too)
  bool _peerOpusReady = true;

  /// the v1 encoder (fixed profile); decoders are created per AAD config
  OpusGateway? _encoder;
  final Map<String, OpusGateway> _decoders = {};

  /// last (timestamp, counter) accepted per senderId
  final Map<int, (int, int)> _watermarks = {};

  /// called with a short reason string for every dropped inbound packet
  /// (protocol.md section 2.6: 'drop and record')
  void Function(String reason)? onDrop;

  /// My own senderId (1 = initiator / 2 = receiver).
  int get localId => _localId;

  /// Whether the Opus path is active (false => PCM16 pass-through).
  bool get opusReady => _opusReady;

  /// Try to bring up the Opus path (native library + encoders); on any
  /// failure the call survives via the PCM16 pass-through (codec='P',
  /// codec.md section 3). Idempotent.
  ///
  /// [opusFactory] overrides the native loader - the tests inject a fake
  /// here. Returns whether the Opus path is ready.
  Future<bool> init({OpusGatewayFactory? opusFactory}) {
    if (_initialized) {
      return Future.value(_opusReady);
    }
    _initialized = true;
    final factory = opusFactory ?? _opusFactory;
    if (factory == createNativeOpusGateway) {
      // load the native library once (the factory only builds the
      // coder pair): a failure here triggers the PCM16 fuse
      return _loadOpus().then((ok) => _createEncoder(factory, ok));
    }
    return Future.value(_createEncoder(factory, true));
  }

  Future<bool> _loadOpus() {
    try {
      return load().then((lib) {
        try {
          opus.initOpus(lib);
          return true;
        } catch (error) {
          return false;
        }
      }).catchError((error) => false);
    } catch (error) {
      return Future.value(false);
    }
  }

  bool _createEncoder(OpusGatewayFactory factory, bool loaded) {
    if (loaded) {
      _encoder = factory(sampleRate: PayloadFormat.defaultSampleRate, channels: PayloadFormat.defaultChannels);
    }
    _opusReady = _encoder != null;
    return _opusReady;
  }

  /// Release every native handle (call on hangup).
  void destroy() {
    _encoder?.destroy();
    _encoder = null;
    for (var decoder in _decoders.values) {
      decoder.destroy();
    }
    _decoders.clear();
    _watermarks.clear();
  }

  //
  //  Sending: PCM frame -> Opus encode -> AES-GCM encrypt -> payload
  //

  /// The main path: PCM frame -> Opus encode -> AES-256-GCM encrypt ->
  /// payload. An empty [frame.pcm] produces the 32-byte KEEPALIVE
  /// (encrypted empty plaintext). Returns null when the frame cannot be
  /// sent (no usable codec path, invalid parameters, ...).
  Uint8List? encodeFrame(VoiceFrame frame) {
    if (_counter >= 0xFFFFFFFF) {
      return _drop('counter-exhausted'); // never wrap (protocol.md 2.2)
    }
    final key = _keys[_localId];
    if (key == null) {
      return _drop('no-send-key');
    }
    final rate = frame.sampleRate ~/ 4000;
    if (frame.sampleRate % 4000 != 0 || !PayloadFormat.validRate(rate)) {
      return _drop('rate');
    }
    final codec = (_opusReady && _peerOpusReady)
        ? PayloadFormat.codecOpus : PayloadFormat.codecPcm;
    Uint8List plaintext;
    if (frame.pcm.isEmpty) {
      plaintext = Uint8List(0); // KEEPALIVE: empty plaintext
    } else if (codec == PayloadFormat.codecOpus) {
      if (frame.sampleRate != PayloadFormat.defaultSampleRate || frame.channels != PayloadFormat.defaultChannels) {
        return _drop('encoder-profile-mismatch');
      }
      if (frame.pcm.length != PayloadFormat.pcmFrameBytes(PayloadFormat.defaultSampleRate, 1)) {
        return _drop('pcm-frame-size'); // fixed 20ms framing
      }
      final encoded = _encoder?.encode(PayloadFormat.pcmToInt16(frame.pcm));
      if (encoded == null) {
        return _drop('opus-encode');
      }
      if (encoded.length > PayloadFormat.maxCiphertextLength) {
        return _drop('oversized'); // ciphertext <= 992 (protocol.md 2)
      }
      plaintext = encoded;
    } else {
      if (PayloadFormat.validChannels(frame.channels) == null) {
        return _drop('channels');
      }
      if (frame.pcm.length != PayloadFormat.pcmFrameBytes(frame.sampleRate, frame.channels)) {
        return _drop('pcm-frame-size'); // fixed 20ms framing
      }
      if (frame.pcm.length > PayloadFormat.maxCiphertextLength) {
        return _drop('oversized'); // ciphertext <= 992 (protocol.md 2)
      }
      plaintext = frame.pcm; // PCM16 pass-through
    }

    final aad = PayloadFormat.buildAad(
      codec: codec,
      rate: frame.sampleRate ~/ 4000,
      channels: frame.channels,
    );
    final nonce = PayloadFormat.buildNonce(
      senderId: _localId,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      counter: _counter + 1,
    );
    final ciphertext = HkdfSha256.encrypt(plaintext, key: key, nonce: nonce, aad: aad);
    _counter += 1;
    var payload = Uint8List(aad.length + nonce.length + ciphertext.length);
    payload.setRange(0, 4, aad);
    payload.setRange(4, 16, nonce);
    payload.setRange(16, payload.length, ciphertext);
    return payload;
  }

  //
  //  Receiving: payload -> validate -> decrypt -> decode -> VoiceFrame
  //

  /// Validate (protocol.md section 2.6) -> decrypt -> decode -> the frame;
  /// null = the packet failed a check and was dropped.
  VoiceFrame? decodeFrame(Uint8List payload) {
    // 1. length at least 32 bytes
    if (payload.length < PayloadFormat.minPayloadLength) {
      return _drop('too-short');
    }
    // 2. AAD: known mediaType/codec/cipher, legal rate/channels
    final aad = payload.sublist(0, 4);
    if (aad[0] != PayloadFormat.mediaTypeAudio) {
      return _drop('media-type');
    }
    final codec = aad[1];
    if (codec != PayloadFormat.codecOpus && codec != PayloadFormat.codecPcm) {
      return _drop('codec');
    }
    if (aad[2] != PayloadFormat.cipherAes256Gcm) {
      return _drop('cipher');
    }
    final rate = aad[3] & 0x0F; // sampleRate / 4000
    if (!PayloadFormat.validRate(rate)) {
      return _drop('rate');
    }
    final category = (aad[3] >> 4) & 0x03; // channel category
    if (category > 2) {
      return _drop('channels');
    }
    // 3. nonce: senderId / timestamp / counter
    final nonce = payload.sublist(4, 16);
    final view = ByteData.sublistView(nonce);
    final senderId = view.getUint32(0, Endian.big);
    final timestamp = view.getUint32(4, Endian.big);
    final counter = view.getUint32(8, Endian.big);
    // 4. reflection guard: the senderId must be the peer's
    if (senderId == _localId) {
      return _drop('reflection');
    }
    // 5. replay guard: (timestamp, counter) strictly increasing per sender
    final last = _watermarks[senderId];
    if (last != null) {
      if (timestamp < last.$1 || (timestamp == last.$1 && counter <= last.$2)) {
        return _drop('replay');
      }
    }
    // 6. AES-256-GCM with the peer's direction key (AAD authenticated)
    final key = _keys[senderId];
    if (key == null) {
      return _drop('no-key');
    }
    final ciphertext = payload.sublist(16, payload.length - 16);
    final tag = payload.sublist(payload.length - 16);
    final plaintext = HkdfSha256.decrypt(
      ciphertext, key: key, nonce: nonce, aad: aad, tag: tag,
    );
    if (plaintext == null) {
      return _drop('tag');
    }
    _watermarks[senderId] = (timestamp, counter);
    // mirror policy: mirror the peer's latest authenticated outbound codec
    _peerOpusReady = codec == PayloadFormat.codecOpus;

    final time = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    if (category == 2) {
      // multistream: v1 defines no parameters yet (protocol.md 2.1)
      return _drop('multistream');
    }
    if (plaintext.isEmpty) {
      // KEEPALIVE: no TOC, no samples, just the restored parameters
      return VoiceFrame(
        pcm: Uint8List(0),
        sampleRate: rate * 4000,
        channels: category + 1,
        senderId: senderId,
        time: time,
      );
    }
    final sampleRate = rate * 4000;
    final channels = category + 1; // 0 = mono, 1 = stereo
    if (codec == PayloadFormat.codecOpus) {
      final gateway = _decoderFor(rate, category);
      if (gateway == null) {
        return _drop('no-opus');
      }
      // the TOC is only read for checks (codec.md 4): the config index
      // 16..31 marks a stereo source - it must match the AAD category
      if (PayloadFormat.tocIsStereo(plaintext[0]) != (channels == 2)) {
        return _drop('toc-mismatch');
      }
      final samples = gateway.decode(plaintext);
      if (samples == null) {
        return _drop('opus-decode');
      }
      return VoiceFrame(
        pcm: PayloadFormat.int16ToPcm(samples),
        sampleRate: sampleRate,
        channels: channels,
        senderId: senderId,
        time: time,
      );
    }
    // PCM16 pass-through: fixed 20ms framing (protocol.md 2.3)
    if (plaintext.length != PayloadFormat.pcmFrameBytes(sampleRate, channels)) {
      return _drop('pcm-frame-size');
    }
    return VoiceFrame(
      pcm: plaintext,
      sampleRate: sampleRate,
      channels: channels,
      senderId: senderId,
      time: time,
    );
  }

  //
  //  Internals
  //

  OpusGateway? _decoderFor(int rate, int category) {
    final key = '$rate:$category';
    var gateway = _decoders[key];
    if (gateway == null) {
      gateway = _opusFactory(sampleRate: rate * 4000, channels: category + 1);
      if (gateway == null) {
        return null;
      }
      _decoders[key] = gateway;
    }
    return gateway;
  }

  // 'Null' (not 'void') so both frame types can 'return _drop(...)'.
  // ignore: prefer_void_to_null
  Null _drop(String reason) {
    onDrop?.call(reason);
    return null;
  }
}
