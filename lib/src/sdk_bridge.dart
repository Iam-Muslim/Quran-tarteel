// lib/src/sdk_bridge.dart
// Direct, zero-fallback bridge from quranlab_tajweedformer SDK outputs to TranscriptionResult.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:quranlab_tajweedformer/quranlab_tajweedformer.dart';

import 'core_types.dart';
import 'reference/quran_repository.dart';

/// Converts SDK [TajweedTokens] into a pure-Dart [PhonemeVocabulary].
PhonemeVocabulary vocabularyFromSdk(TajweedTokens tokens) => PhonemeVocabulary(
      names: tokens.names,
      blank: tokens.blank,
      wordBar: tokens.wordBar,
    );

/// Convenience SDK loaders on [QuranRepository].
extension QuranRepositorySdkExtension on QuranRepository {
  /// Loads `expected_tj3.zfx` bytes directly using SDK [TajweedTokens].
  ///
  /// When [expectedTokensSha256] is provided, verifies it against the `.zfx`
  /// header digest and throws [QuranTarteelException] on mismatch.
  void loadSdkBytes(
    Uint8List bytes, {
    required TajweedTokens tokens,
    String? expectedTokensSha256,
    bool forceReload = false,
  }) {
    loadBytes(
      bytes,
      vocabulary: vocabularyFromSdk(tokens),
      expectedTokensSha256: expectedTokensSha256,
      forceReload: forceReload,
    );
  }

  /// Loads `expected_tj3.zfx` bytes directly from an open [TajweedModel],
  /// verifying [TajweedCalibration.tokensSha256] when [verifyTokensSha256] is
  /// `true`. Throws [QuranTarteelException] if verification is enabled and the
  /// model exposes no `tokensSha256`.
  void loadModelBytes(
    Uint8List bytes, {
    required TajweedModel model,
    bool verifyTokensSha256 = true,
    bool forceReload = false,
  }) {
    String? sha;
    if (verifyTokensSha256) {
      final String? modelSha = model.calibration?.tokensSha256;
      if (modelSha == null || modelSha.isEmpty) {
        throw const QuranTarteelException(
          QuranTarteelErrorCode.missingCalibrationThreshold,
          'model.calibration.tokensSha256 is required when verifyTokensSha256 is true',
        );
      }
      sha = modelSha;
    }
    loadBytes(
      bytes,
      vocabulary: vocabularyFromSdk(model.tokens),
      expectedTokensSha256: sha,
      forceReload: forceReload,
    );
  }
}

/// Stateless/per-take extractor that converts [TajweedChunk] and [TajweedHeads]
/// outputs from `quranlab_tajweedformer` into [TranscriptionResult]s without owning
/// client/model lifecycles or swallowing SDK errors.
class TajweedTakeDecoder {
  static const int defaultTopK = 6;
  static const double defaultMinKeepProb = 0.01;

  /// Active heads per architectural invariant: `log_probs`, `attr_qalqalah`, `conf`.
  static const List<String> activeHeads = <String>[
    'log_probs',
    'attr_qalqalah',
    'conf',
  ];

  /// Minimal heads for word tracking without Qalqalah scoring.
  static const List<String> wordOnlyHeads = <String>[
    'log_probs',
    'conf',
  ];

  final TajweedTokens vocab;
  final bool requireQalqalahHead;
  final double minKeepProb;

  final List<double> _qalqalahFrameProbs = [];
  final List<Map<int, double>> _altProbs = [];
  int? _qalqalahFrameMs;
  int _lastChunkFirstFrame = -1;

  TajweedTakeDecoder({
    required this.vocab,
    this.requireQalqalahHead = true,
    this.minKeepProb = defaultMinKeepProb,
  }) {
    if (vocab.names.isEmpty) {
      throw const QuranTarteelException(
        QuranTarteelErrorCode.invalidReferenceData,
      );
    }
    if (minKeepProb < 0.0 || minKeepProb > 1.0 || minKeepProb.isNaN) {
      throw RangeError.range(minKeepProb, 0, 1, 'minKeepProb');
    }
  }

  /// Resolves the validated Qalqalah threshold from `model.calibration`, or returns
  /// `null` when unavailable or not `'validated'` for the target context/preset.
  static double? resolveValidatedQalqalahTau(
    TajweedModel model, {
    String? context,
    String? preset,
  }) {
    final cal = model.calibration;
    if (cal == null) return null;
    final String ctx = context ?? model.defaultContext;
    final String? resolvedPreset = preset ?? cal.defaultPreset;
    if (resolvedPreset == null) return null;
    if (cal.status(ctx, 'qalqalah') != 'validated') return null;
    return cal.threshold(ctx, 'qalqalah', resolvedPreset);
  }

  /// Resolves the validated Qalqalah threshold from `model.calibration`, or throws
  /// [QuranTarteelException] with [QuranTarteelErrorCode.missingCalibrationThreshold].
  static double requireValidatedQalqalahTau(
    TajweedModel model, {
    String? context,
    String? preset,
  }) {
    final double? tau = resolveValidatedQalqalahTau(
      model,
      context: context,
      preset: preset,
    );
    if (tau == null) {
      throw const QuranTarteelException(
        QuranTarteelErrorCode.missingCalibrationThreshold,
        'Validated qalqalah threshold is missing from model.calibration',
      );
    }
    return tau;
  }

  /// Clears per-take frame caches (e.g. before a new take or backend reset).
  void resetTake() {
    _qalqalahFrameProbs.clear();
    _altProbs.clear();
    _qalqalahFrameMs = null;
    _lastChunkFirstFrame = -1;
  }

  /// Decodes a streaming [TajweedChunk] into a [TranscriptionResult].
  TranscriptionResult decodeChunk(
    TajweedChunk chunk, {
    int streamEpoch = 0,
  }) {
    if (chunk.firstFrame <= _lastChunkFirstFrame) {
      if (chunk.firstFrame == 0) {
        _qalqalahFrameProbs.clear();
        _altProbs.clear();
      } else {
        final int? qalMs = _qalqalahFrameMs;
        final logProbsHead = chunk.heads['log_probs'];
        if (qalMs != null && qalMs > 0 && logProbsHead != null) {
          final int trimQal =
              chunk.firstFrame * (logProbsHead.frameMs ~/ qalMs);
          if (_qalqalahFrameProbs.length > trimQal) {
            _qalqalahFrameProbs.removeRange(trimQal, _qalqalahFrameProbs.length);
          }
        }
        final int keepTokens = chunk.decoded.tokens
            .takeWhile((t) => t.lastMs < chunk.startMs)
            .length;
        if (_altProbs.length > keepTokens) {
          _altProbs.removeRange(keepTokens, _altProbs.length);
        }
      }
    }
    _lastChunkFirstFrame = chunk.firstFrame;

    return _decode(
      decoded: chunk.decoded,
      heads: chunk.heads,
      startMs: chunk.startMs,
      endMs: chunk.endMs,
      firstFrame: chunk.firstFrame,
      streamEpoch: streamEpoch,
    );
  }

  /// Decodes final [TajweedHeads] returned by `TajweedSession.finish()`.
  TranscriptionResult decodeFinishedHeads(
    TajweedHeads heads, {
    int streamEpoch = 0,
  }) {
    final decoded = heads.decoded();
    final logProbsHead = heads['log_probs'];
    if (logProbsHead == null || logProbsHead.frameMs <= 0) {
      throw const QuranTarteelException(
        QuranTarteelErrorCode.missingAcousticHead,
      );
    }
    return _decode(
      decoded: decoded,
      heads: heads,
      startMs: 0,
      endMs: decoded.frames.length * logProbsHead.frameMs,
      firstFrame: 0,
      streamEpoch: streamEpoch,
    );
  }

  TranscriptionResult _decode({
    required TajweedDecoded decoded,
    required TajweedHeads heads,
    required int startMs,
    required int endMs,
    required int firstFrame,
    required int streamEpoch,
  }) {
    final TajweedHead? logProbsHead = heads['log_probs'];
    if (logProbsHead == null || logProbsHead.frameMs <= 0) {
      throw const QuranTarteelException(
        QuranTarteelErrorCode.missingAcousticHead,
      );
    }
    final int baseFrameMs = logProbsHead.frameMs;
    final TajweedHead? qalqalahHead = heads['attr_qalqalah'];

    if (requireQalqalahHead) {
      if (qalqalahHead == null ||
          qalqalahHead.classes < 3 ||
          qalqalahHead.frameMs <= 0 ||
          (qalqalahHead.frames <= 0 && decoded.tokens.isNotEmpty)) {
        throw const QuranTarteelException(
          QuranTarteelErrorCode.missingAcousticHead,
        );
      }
    }

    if (qalqalahHead != null &&
        qalqalahHead.frames > 0 &&
        qalqalahHead.classes >= 3 &&
        qalqalahHead.frameMs > 0) {
      final int frameMs = qalqalahHead.frameMs;
      _qalqalahFrameMs = frameMs;
      final int chunkOffset = firstFrame * (baseFrameMs ~/ frameMs);
      final int needed = chunkOffset + qalqalahHead.frames;
      while (_qalqalahFrameProbs.length < needed) {
        _qalqalahFrameProbs.add(0.0);
      }
      for (int f = 0; f < qalqalahHead.frames; f++) {
        _qalqalahFrameProbs[chunkOffset + f] =
            qalqalahHead.at(f, 1) + qalqalahHead.at(f, 2);
      }
    }

    final int count = decoded.tokens.length;
    final List<String> tokenStrings = List<String>.filled(count, '');
    final List<double> timestamps = List<double>.filled(count, 0.0);
    final List<double> tokenDurations = List<double>.filled(count, 0.0);
    final List<TokenNeuralAcoustics> tokenAcoustics =
        List<TokenNeuralAcoustics>.filled(count, const TokenNeuralAcoustics());

    for (int i = 0; i < count; i++) {
      final token = decoded.tokens[i];
      tokenStrings[i] = token.name;
      timestamps[i] = token.lastMs / 1000.0;
      tokenDurations[i] = (token.lastMs - token.firstMs) / 1000.0;

      final double qalScore =
          (qalqalahHead != null && _qalqalahFrameProbs.isNotEmpty)
              ? extractTokenQalqalahScore(
                  tokenIndex: i,
                  tokens: decoded.tokens,
                  frameProbs: _qalqalahFrameProbs,
                  frameMs: qalqalahHead.frameMs,
                  baseFrameMs: baseFrameMs,
                )
              : 0.0;

      Map<int, double> altProbs = const {};
      if (i < _altProbs.length && token.lastMs < startMs) {
        altProbs = _altProbs[i];
      } else {
        final extracted = extractTokenAltProbs(
          token: token,
          frames: decoded.frames,
          vocabNames: vocab.names,
          blankId: vocab.blank,
          wordBarId: vocab.wordBar,
          minKeepProb: minKeepProb,
          frameMs: baseFrameMs,
        );
        if (extracted.isNotEmpty) {
          altProbs = extracted;
          while (_altProbs.length <= i) {
            _altProbs.add(const {});
          }
          _altProbs[i] = altProbs;
        } else if (i < _altProbs.length) {
          altProbs = _altProbs[i];
        }
      }

      tokenAcoustics[i] = TokenNeuralAcoustics(
        qalqalahScore: qalScore,
        confScore: token.confidence,
        altProbs: altProbs,
      );
    }

    return TranscriptionResult(
      text: formatDecodedText(decoded.tokens),
      isFinal: decoded.isFinal,
      startTime: startMs,
      tokens: tokenStrings,
      timestamps: timestamps,
      durations: tokenDurations,
      neuralAcoustics: tokenAcoustics,
      streamEpoch: streamEpoch,
      audioElapsedSeconds: endMs / 1000.0,
    );
  }

  /// Formats [TajweedDecoded.tokens] into continuous word-grouped phonetic text:
  /// word bar `|` becomes a single space `' '` and phonemes within a word are joined directly.
  static String formatDecodedText(List<TajweedToken> tokens) {
    final buf = StringBuffer();
    for (final token in tokens) {
      final String tok = token.name;
      if (tok == '|') {
        if (buf.isNotEmpty && !buf.toString().endsWith(' ')) {
          buf.write(' ');
        }
      } else if (!PhoneticSymbols.isControlToken(tok)) {
        buf.write(tok);
      }
    }
    return buf.toString().trimRight();
  }

  /// Extracts `P(burst) = mean of attr_qalqalah[:,1] + attr_qalqalah[:,2]` over
  /// the 12 frames (`240 ms`) `[e+2, e+14)` following the token's end `e`.
  static double extractTokenQalqalahScore({
    required int tokenIndex,
    required List<TajweedToken> tokens,
    required List<double> frameProbs,
    required int frameMs,
    required int baseFrameMs,
  }) {
    if (tokenIndex < 0 || tokenIndex >= tokens.length || frameProbs.isEmpty) {
      return 0.0;
    }
    final int safeFrameMs = max(1, frameMs);
    final int safeBaseMs = max(safeFrameMs, baseFrameMs);
    final TajweedToken token = tokens[tokenIndex];
    final int endFrame = (token.lastMs + safeBaseMs) ~/ safeFrameMs;

    int nextStartFrame = frameProbs.length;
    for (int j = tokenIndex + 1; j < tokens.length; j++) {
      if (PhoneticSymbols.isControlToken(tokens[j].name)) continue;
      nextStartFrame = tokens[j].firstMs ~/ safeFrameMs;
      break;
    }

    const int windowFrames = 12;
    final int winStartMin = endFrame + 2;
    if (winStartMin >= frameProbs.length) return 0.0;

    final int winStartMax =
        max(winStartMin, min(nextStartFrame, endFrame + 14));
    final int lastValidStart =
        min(winStartMax, max(winStartMin, frameProbs.length - windowFrames));

    double bestMean = 0.0;
    for (int st = winStartMin; st <= lastValidStart; st++) {
      final int end = min(frameProbs.length, st + windowFrames);
      if (end <= st) continue;
      double sum = 0.0;
      for (int f = st; f < end; f++) {
        sum += frameProbs[f];
      }
      final double mean = sum / (end - st);
      if (mean > bestMean) bestMean = mean;
    }
    return bestMean;
  }

  /// Extracts peak per-phoneme probabilities `[0.0, 1.0]` over [token]'s active
  /// frames directly from SDK `frames` (`topK`/`topKLogProbs`).
  static Map<int, double> extractTokenAltProbs({
    required TajweedToken token,
    required List<TajweedFrame> frames,
    required List<String> vocabNames,
    required int blankId,
    int? wordBarId,
    double minKeepProb = defaultMinKeepProb,
    required int frameMs,
  }) {
    if (frames.isEmpty) return const {};
    final Map<int, double> result = <int, double>{};
    final int safeFrameMs = max(1, frameMs);
    final int fStart = max(0, token.firstMs ~/ safeFrameMs);
    final int fEnd =
        min(frames.length - 1, max(fStart, token.lastMs ~/ safeFrameMs));

    for (int f = fStart; f <= fEnd; f++) {
      final frame = frames[f];
      if (frame.topK.length != frame.topKLogProbs.length) continue;
      for (int k = 0; k < frame.topK.length; k++) {
        final int clsId = frame.topK[k];
        if (clsId == blankId || clsId == wordBarId) continue;
        if (clsId < 0 || clsId >= vocabNames.length) continue;
        final String name = vocabNames[clsId];
        if (PhoneticSymbols.isControlToken(name)) continue;
        final double prob = exp(frame.topKLogProbs[k]).clamp(0.0, 1.0);
        if (prob < minKeepProb) continue;
        final int code = name.codeUnitAt(0);
        final double prev = result[code] ?? 0.0;
        if (prob > prev) result[code] = prob;
      }
    }
    return result;
  }

  /// Convenience stream transformer converting a live `TajweedSession.chunks` stream
  /// into decoded [TranscriptionResult]s for model-output-only consumers or custom pipelines.
  static Stream<TranscriptionResult> decodeSessionStream(
    TajweedSession session, {
    required TajweedTokens vocab,
    bool requireQalqalahHead = true,
    double minKeepProb = defaultMinKeepProb,
    int streamEpoch = 0,
  }) {
    final decoder = TajweedTakeDecoder(
      vocab: vocab,
      requireQalqalahHead: requireQalqalahHead,
      minKeepProb: minKeepProb,
    );
    return session.chunks.map(
      (chunk) => decoder.decodeChunk(chunk, streamEpoch: streamEpoch),
    );
  }
}
