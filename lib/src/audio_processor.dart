// lib/src/audio_processor.dart
// Unified raw 16 kHz Float32 PCM microphone capture for TajweedFormer V4 streams.

import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

/// Stateful helper that accumulates PCM-16LE bytes (handling odd-byte frame splits)
/// and converts aligned sample pairs into normalized Float32 samples in `[-1.0, 1.0]`.
class Pcm16StreamNormalizer {
  int? _carryByte;

  /// Clears any trailing odd byte carried from a previous packet.
  void reset() {
    _carryByte = null;
  }

  /// Converts [rawData] bytes (PCM-16LE) into normalized [Float32List] samples,
  /// preserving any trailing odd byte across calls until the next byte arrives.
  Float32List? push(Uint8List rawData) {
    if (rawData.isEmpty) return null;

    final Uint8List bytes;
    if (_carryByte != null) {
      bytes = Uint8List(rawData.length + 1)
        ..[0] = _carryByte!
        ..setRange(1, rawData.length + 1, rawData);
      _carryByte = null;
    } else {
      bytes = rawData;
    }

    final int evenBytes = bytes.length & ~1;
    if (bytes.length.isOdd) {
      _carryByte = bytes[bytes.length - 1];
    }
    if (evenBytes == 0) return null;

    final byteData = ByteData.sublistView(bytes, 0, evenBytes);
    final int sampleCount = evenBytes ~/ AudioProcessor.bytesPerSample;
    final float32Samples = Float32List(sampleCount);

    for (int i = 0; i < sampleCount; i++) {
      float32Samples[i] = byteData.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return float32Samples;
  }
}

/// Captures raw 16 kHz mono PCM-16 microphone audio via `package:record` and
/// emits normalized [Float32List] chunks suitable for `TajweedSession.push()`.
class AudioProcessor {
  static const int recordSampleRate = 16000;
  static const int numChannels = 1;
  static const int bytesPerSample = 2; // 16-bit PCM

  final Pcm16StreamNormalizer _normalizer = Pcm16StreamNormalizer();
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _subscription;

  /// Checks (and prompts if needed) for OS microphone recording permission.
  Future<bool> hasPermission() async {
    final recorder = AudioRecorder();
    try {
      return await recorder.hasPermission();
    } finally {
      await recorder.dispose();
    }
  }

  /// Starts streaming raw 16 kHz Float32 PCM chunks to [onChunk].
  Future<void> start({
    required void Function(Float32List chunk, bool isFinal) onChunk,
    void Function(Object error, StackTrace stackTrace)? onError,
    RecordConfig? config,
  }) async {
    await stop();

    _recorder = AudioRecorder();
    _normalizer.reset();

    final recordStream = await _recorder!.startStream(
      config ??
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: recordSampleRate,
            numChannels: numChannels,
            autoGain: false,
            echoCancel: false,
            noiseSuppress: false,
          ),
    );

    _subscription = recordStream.listen(
      (Uint8List rawData) {
        final samples = _normalizer.push(rawData);
        if (samples != null) {
          onChunk(samples, false);
        }
      },
      onError: onError,
      cancelOnError: false,
    );
  }

  /// Resets the internal odd-byte carry buffer without stopping the recorder.
  void clearBuffer() {
    _normalizer.reset();
  }

  /// Stops recording and releases the underlying [AudioRecorder].
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;

    try {
      if (_recorder != null && await _recorder!.isRecording()) {
        await _recorder!.stop();
      }
    } finally {
      await _recorder?.dispose();
      _recorder = null;
      _normalizer.reset();
    }
  }
}
