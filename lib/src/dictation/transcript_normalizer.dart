// lib/src/dictation/transcript_normalizer.dart
import 'dart:math';

import '../config.dart';
import '../core_types.dart';

/// Character-aligned phoneme sequence, timings, and neural acoustics produced
/// from a raw [TranscriptionResult] after filtering control tokens.
class NormalizedTranscript {
  final List<String> tokens;
  final List<double> durations;
  final List<double> starts;
  final List<double> ends;
  final List<TokenNeuralAcoustics> neuralAcoustics;
  final double? audioElapsedSeconds;

  NormalizedTranscript({
    required this.tokens,
    required this.durations,
    this.starts = const [],
    this.ends = const [],
    this.neuralAcoustics = const [],
    this.audioElapsedSeconds,
  });

  bool get isEmpty => tokens.isEmpty;

  String? _text;
  String get text => _text ??= tokens.join('');

  List<int>? _charTokenIndices;
  List<int> get charTokenIndices =>
      _charTokenIndices ??= _computeCharTokenIndices();

  List<int> _computeCharTokenIndices() {
    final List<int> result = [];
    for (int i = 0; i < tokens.length; i++) {
      final int len = tokens[i].length;
      for (int c = 0; c < len; c++) {
        result.add(i);
      }
    }
    return result;
  }

  List<double>? _charTimestamps;
  List<double> get charTimestamps =>
      _charTimestamps ??= _computeCharTimestamps();

  List<double> _computeCharTimestamps() {
    final List<double> result = [];
    for (int i = 0; i < tokens.length; i++) {
      final tok = tokens[i];
      final double s = starts.isNotEmpty && i < starts.length ? starts[i] : 0.0;
      final double durPerChar = durations[i] / max(1, tok.length);
      for (int c = 0; c < tok.length; c++) {
        result.add(s + (c + 1) * durPerChar);
      }
    }
    if (result.isNotEmpty &&
        audioElapsedSeconds != null &&
        audioElapsedSeconds! > result.last) {
      result[result.length - 1] = audioElapsedSeconds!;
    }
    return result;
  }

  List<TokenNeuralAcoustics>? _charNeuralAcoustics;
  List<TokenNeuralAcoustics> get charNeuralAcoustics =>
      _charNeuralAcoustics ??= _computeCharNeuralAcoustics();

  List<TokenNeuralAcoustics> _computeCharNeuralAcoustics() {
    final List<TokenNeuralAcoustics> result = [];
    for (int i = 0; i < tokens.length; i++) {
      final tok = tokens[i];
      final acoustics = i < neuralAcoustics.length
          ? neuralAcoustics[i]
          : const TokenNeuralAcoustics();
      for (int c = 0; c < tok.length; c++) {
        result.add(acoustics);
      }
    }
    return result;
  }
}

/// Filters ASR control tokens (`<blk>`, `|`), clamps durations, and expands
/// multi-character tokens into character-aligned inputs for alignment.
class TranscriptNormalizer {
  static const double _minTokenDurationSeconds = 0.020;

  TrackerConfig config;

  TranscriptNormalizer({this.config = const TrackerConfig()});

  final List<String> _filteredTokens = [];
  final List<TokenNeuralAcoustics> _filteredAcoustics = [];
  final List<double> _tokenDurations = [];
  final List<double> _tokenStarts = [];
  final List<double> _tokenEnds = [];

  void reset() {
    _filteredTokens.clear();
    _filteredAcoustics.clear();
    _tokenDurations.clear();
    _tokenStarts.clear();
    _tokenEnds.clear();
  }

  NormalizedTranscript normalize(TranscriptionResult result) {
    final int maxCount = min(result.tokens.length, result.timestamps.length);

    _filteredTokens.clear();
    _filteredAcoustics.clear();
    _tokenDurations.clear();
    _tokenStarts.clear();
    _tokenEnds.clear();

    for (int i = 0; i < maxCount; i++) {
      final String tok = result.tokens[i];
      if (PhoneticSymbols.isControlToken(tok)) {
        continue;
      }

      final double endTs = result.timestamps[i];
      final double dur =
          i < result.durations.length ? result.durations[i] : 0.0;
      final double startTs = max(0.0, endTs - dur);

      _filteredTokens.add(tok);
      _tokenEnds.add(endTs);
      _tokenStarts.add(startTs);
      _tokenDurations.add(
        dur.clamp(_minTokenDurationSeconds, config.maxTokenDurationAllowed),
      );
      _filteredAcoustics.add(
        i < result.neuralAcoustics.length
            ? result.neuralAcoustics[i]
            : const TokenNeuralAcoustics(),
      );
    }

    return NormalizedTranscript(
      tokens: _filteredTokens,
      durations: _tokenDurations,
      starts: _tokenStarts,
      ends: _tokenEnds,
      neuralAcoustics: _filteredAcoustics,
      audioElapsedSeconds: result.audioElapsedSeconds,
    );
  }
}
