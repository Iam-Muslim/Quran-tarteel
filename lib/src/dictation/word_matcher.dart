// lib/src/dictation/word_matcher.dart
import 'dart:math';
import 'dart:typed_data';

import '../config.dart';
import '../core_types.dart';
import '../tajweed/tajweed_types.dart';

class WordMatchResult {
  final double pathCost;
  final int tokensConsumed;
  final int matchStart;
  final String cleanAsr;
  final List<double> timestamps;
  final List<PhonemeGroupAlignment> trace;

  const WordMatchResult({
    required this.pathCost,
    required this.tokensConsumed,
    this.matchStart = 0,
    required this.cleanAsr,
    required this.timestamps,
    required this.trace,
  });
}

class PhoneticCostEngine {
  static bool _isZeroCostMarker(int codeUnit) =>
      codeUnit == PhoneticSymbols.wordBarCodeUnit;

  static int countBaseConsonants(
    String fullPhonemes,
    int refStart,
    int refEnd,
  ) {
    final int limit = min(refEnd, fullPhonemes.length);
    int count = 0;
    for (int j = refStart; j < limit; j++) {
      final int code = fullPhonemes.codeUnitAt(j);
      if (_isZeroCostMarker(code) || PhoneticSymbols.isVowelChar(code)) {
        continue;
      }
      if (j > refStart && code == fullPhonemes.codeUnitAt(j - 1)) continue;
      count++;
    }
    return count;
  }

  static bool _isAtWordEnd(String fullPhonemes, int idx, int end) {
    final int limit = min(end, fullPhonemes.length);
    for (int j = idx + 1; j < limit; j++) {
      if (!_isZeroCostMarker(fullPhonemes.codeUnitAt(j))) return false;
    }
    return true;
  }

  static double getSubstitutionCost(
    int asrCodeUnit,
    int refCodeUnit,
    double acousticConfusionCost,
    String asrText,
    int asrIdx,
    String fullPhonemes,
    int refIdx,
    TokenNeuralAcoustics? asrAcoustics,
    double minAltProb,
  ) {
    if (asrCodeUnit == refCodeUnit) return 0.0;

    if (PhoneticSymbols.isVowelChar(asrCodeUnit) &&
        PhoneticSymbols.isVowelChar(refCodeUnit)) {
      final bool asrMadd = PhoneticSymbols.isMaddLongVowel(asrText, asrIdx);
      final bool refMadd =
          PhoneticSymbols.isMaddLongVowel(fullPhonemes, refIdx);
      if (!asrMadd && !refMadd) {
        return acousticConfusionCost;
      }
      return 1.00;
    }

    if (asrAcoustics != null &&
        !PhoneticSymbols.isVowelChar(asrCodeUnit) &&
        !PhoneticSymbols.isVowelChar(refCodeUnit)) {
      if (asrAcoustics.probOf(refCodeUnit) >= minAltProb) {
        return acousticConfusionCost;
      }
    }

    return 1.00;
  }

  static double getDeletionCost(
    String fullPhonemes,
    int gRefIdx,
    double standardDeletionCost,
    double acousticConfusionCost,
    int refEnd,
    int refStart,
  ) {
    if (gRefIdx < refStart || gRefIdx >= fullPhonemes.length) {
      return standardDeletionCost;
    }
    final int code = fullPhonemes.codeUnitAt(gRefIdx);

    if (_isZeroCostMarker(code)) return 0.0;

    if (gRefIdx > refStart && code == fullPhonemes.codeUnitAt(gRefIdx - 1)) {
      return acousticConfusionCost;
    }

    if (PhoneticSymbols.isTashkeelChar(fullPhonemes, gRefIdx)) {
      return _isAtWordEnd(fullPhonemes, gRefIdx, refEnd)
          ? 0.0
          : acousticConfusionCost;
    }

    return standardDeletionCost;
  }

  static double getInsertionCost(
    String asrText,
    int asrIdx,
    double standardInsertionCost,
    double acousticConfusionCost,
    double shortVowelInsertCap,
  ) {
    if (asrIdx < 0 || asrIdx >= asrText.length) return standardInsertionCost;
    final int code = asrText.codeUnitAt(asrIdx);

    if (_isZeroCostMarker(code)) return 0.0;

    if (asrIdx > 0 && code == asrText.codeUnitAt(asrIdx - 1)) {
      return acousticConfusionCost;
    }

    if (PhoneticSymbols.isVowelChar(code)) {
      return min(standardInsertionCost, shortVowelInsertCap);
    }

    return standardInsertionCost;
  }
}

class _AlignedTraceSummary {
  final int matchStart;
  final int matchedConsonants;
  final int refConsonants;
  final int acousticOverlapSubs;
  final int nonAcousticConsSubs;
  final int highConfNonAcousticConsSubs;
  final int missingBaseConsonants;
  final bool deletedFirstConsonant;
  final bool deletedLastConsonant;
  final int maddQualityErrors;
  final List<double> timestamps;
  final List<PhonemeGroupAlignment> trace;

  const _AlignedTraceSummary({
    required this.matchStart,
    required this.matchedConsonants,
    required this.refConsonants,
    required this.acousticOverlapSubs,
    required this.nonAcousticConsSubs,
    required this.highConfNonAcousticConsSubs,
    required this.missingBaseConsonants,
    required this.deletedFirstConsonant,
    required this.deletedLastConsonant,
    required this.maddQualityErrors,
    required this.timestamps,
    required this.trace,
  });
}

class QuranDictationMatcher {
  static const double _repeatedCharWeight = 0.25;
  static const double _medialShortVowelWeight = 0.25;
  static const double _baseStructuralWeight = 1.0;
  static const double _minStructuralWeight = 1.0;
  static const double _shortVowelInsertCap = 0.25;
  static const double _shortWordMaxWeight = 2.75;
  static const double _mediumWordMaxWeight = 5.5;

  Float64List _dp = Float64List(2048);
  Uint8List _bt = Uint8List(2048);

  WordMatchResult? matchWord({
    required String asrText,
    required List<double> asrTimestamps,
    required String fullPhonemes,
    required int refStart,
    required int refEnd,
    TrackerConfig config = const TrackerConfig(),
    bool isTajweed = false,
    double? maxCostOverride,
    List<TokenNeuralAcoustics>? asrAcoustics,
  }) {
    final int m = asrText.length;
    final int n = refEnd - refStart;
    if (m == 0 || n <= 0) return null;

    final int stride = n + 1;
    final int cells = (m + 1) * stride;
    if (_dp.length < cells) {
      final int sz = max(cells, _dp.length * 2);
      _dp = Float64List(sz);
      _bt = Uint8List(sz);
    }

    final dp = _dp;
    final bt = _bt;
    final policy = config.policy;

    _initializeGrid(
      dp: dp,
      bt: bt,
      fullPhonemes: fullPhonemes,
      refStart: refStart,
      refEnd: refEnd,
      m: m,
      n: n,
      stride: stride,
      config: config,
    );

    _fillGrid(
      dp: dp,
      bt: bt,
      asrText: asrText,
      asrAcoustics: asrAcoustics,
      fullPhonemes: fullPhonemes,
      refStart: refStart,
      refEnd: refEnd,
      m: m,
      n: n,
      stride: stride,
      config: config,
    );

    final double structWeight = _computeStructuralWeight(
      fullPhonemes,
      refStart,
      refEnd,
    );
    final int refConsonants = PhoneticCostEngine.countBaseConsonants(
      fullPhonemes,
      refStart,
      refEnd,
    );
    final double threshold = _resolveThreshold(
      structWeight: structWeight,
      refConsonants: refConsonants,
      policy: policy,
      maxCostOverride: maxCostOverride,
    );

    final bool refEndsInShortVowel = PhoneticSymbols.isTashkeelChar(
      fullPhonemes,
      refEnd - 1,
    );
    int bestI = -1;
    double bestCost = double.infinity;
    for (int i = 1; i <= m; i++) {
      final double norm = dp[i * stride + n] / structWeight;
      if (norm <= threshold) {
        final int opAtEnd = bt[i * stride + n];
        final bool strictlyBetter = norm < bestCost - 1e-9;
        final int prevAsrCode = asrText.codeUnitAt(i - 1);
        final int endRefCode = fullPhonemes.codeUnitAt(refEnd - 1);
        final bool consumesExactTerminal =
            i == bestI + 1 &&
            (norm - bestCost).abs() <= 1e-9 &&
            opAtEnd == 0 &&
            prevAsrCode == endRefCode &&
            PhoneticSymbols.isVowelChar(endRefCode);
        final bool consumesSwappedTerminal =
            i == bestI + 1 &&
            opAtEnd == 0 &&
            refEndsInShortVowel &&
            PhoneticSymbols.isVowelChar(prevAsrCode) &&
            prevAsrCode != endRefCode &&
            norm <=
                bestCost + config.acousticConfusionCost / structWeight + 1e-9;
        if (strictlyBetter || consumesExactTerminal) {
          bestI = i;
          bestCost = norm;
        } else if (consumesSwappedTerminal) {
          bestI = i;
        }
      }
    }

    if (bestI < 0) return null;

    final summary = _tracebackAndVerify(
      bt: bt,
      stride: stride,
      bestI: bestI,
      n: n,
      asrText: asrText,
      asrTimestamps: asrTimestamps,
      asrAcoustics: asrAcoustics,
      fullPhonemes: fullPhonemes,
      refStart: refStart,
      refEnd: refEnd,
      config: config,
      isTajweed: isTajweed,
    );

    if (!_passesStructuralCheck(
      summary: summary,
      policy: policy,
    )) {
      return null;
    }

    return WordMatchResult(
      pathCost: bestCost,
      tokensConsumed: bestI,
      matchStart: summary.matchStart,
      cleanAsr: asrText.substring(summary.matchStart, bestI),
      timestamps: summary.timestamps,
      trace: summary.trace,
    );
  }

  void _initializeGrid({
    required Float64List dp,
    required Uint8List bt,
    required String fullPhonemes,
    required int refStart,
    required int refEnd,
    required int m,
    required int n,
    required int stride,
    required TrackerConfig config,
  }) {
    dp[0] = 0.0;
    bt[0] = 0;

    for (int j = 1; j <= n; j++) {
      final double delCost = PhoneticCostEngine.getDeletionCost(
        fullPhonemes,
        refStart + j - 1,
        config.standardDeletionCost,
        config.acousticConfusionCost,
        refEnd,
        refStart,
      );
      dp[j] = dp[j - 1] + delCost;
      bt[j] = 1;
    }

    for (int i = 1; i <= m; i++) {
      dp[i * stride] = 0.0;
      bt[i * stride] = 2;
    }
  }

  void _fillGrid({
    required Float64List dp,
    required Uint8List bt,
    required String asrText,
    required List<TokenNeuralAcoustics>? asrAcoustics,
    required String fullPhonemes,
    required int refStart,
    required int refEnd,
    required int m,
    required int n,
    required int stride,
    required TrackerConfig config,
  }) {
    final double minAltProb = config.minAltProbThreshold;
    for (int i = 1; i <= m; i++) {
      final int aCode = asrText.codeUnitAt(i - 1);
      final TokenNeuralAcoustics? tokenAcoustics =
          (asrAcoustics != null && (i - 1) < asrAcoustics.length)
              ? asrAcoustics[i - 1]
              : null;
      final int row = i * stride;
      final int prev = (i - 1) * stride;
      final double insCost = PhoneticCostEngine.getInsertionCost(
        asrText,
        i - 1,
        config.standardInsertionCost,
        config.acousticConfusionCost,
        _shortVowelInsertCap,
      );

      for (int j = 1; j <= n; j++) {
        final int rRef = refStart + j - 1;
        final int rCode = fullPhonemes.codeUnitAt(rRef);

        final double subCost = PhoneticCostEngine.getSubstitutionCost(
          aCode,
          rCode,
          config.acousticConfusionCost,
          asrText,
          i - 1,
          fullPhonemes,
          rRef,
          tokenAcoustics,
          minAltProb,
        );
        final double delCost = PhoneticCostEngine.getDeletionCost(
          fullPhonemes,
          rRef,
          config.standardDeletionCost,
          config.acousticConfusionCost,
          refEnd,
          refStart,
        );

        final double sub = dp[prev + j - 1] + subCost;
        final double del = dp[row + j - 1] + delCost;
        final double ins = dp[prev + j] + insCost;

        final bool bothVowels = PhoneticSymbols.isVowelChar(aCode) &&
            PhoneticSymbols.isVowelChar(rCode);
        final bool preferSub = bothVowels ? sub <= del : sub < del;
        if (preferSub && sub <= ins) {
          dp[row + j] = sub;
          bt[row + j] = 0;
        } else if (del <= ins) {
          dp[row + j] = del;
          bt[row + j] = 1;
        } else {
          dp[row + j] = ins;
          bt[row + j] = 2;
        }
      }
    }
  }

  double _computeStructuralWeight(
    String fullPhonemes,
    int refStart,
    int refEnd,
  ) {
    double weight = 0.0;
    for (int j = refStart; j < refEnd; j++) {
      final int code = fullPhonemes.codeUnitAt(j);
      if (PhoneticCostEngine._isZeroCostMarker(code)) continue;
      if (PhoneticSymbols.isMaddLongVowel(fullPhonemes, j)) {
        final bool isSecond =
            j > refStart && code == fullPhonemes.codeUnitAt(j - 1);
        weight += isSecond ? _repeatedCharWeight : _baseStructuralWeight;
      } else if (PhoneticSymbols.isVowelChar(code)) {
        if (!PhoneticCostEngine._isAtWordEnd(fullPhonemes, j, refEnd)) {
          weight += _medialShortVowelWeight;
        }
      } else {
        final bool isRepeatConsonant =
            j > refStart && code == fullPhonemes.codeUnitAt(j - 1);
        weight += isRepeatConsonant
            ? _repeatedCharWeight
            : _baseStructuralWeight;
      }
    }
    return max(_minStructuralWeight, weight);
  }

  double _resolveThreshold({
    required double structWeight,
    required int refConsonants,
    required MatchingPolicy policy,
    double? maxCostOverride,
  }) {
    if (maxCostOverride != null) return maxCostOverride;
    if (refConsonants <= policy.shortWordMaxConsonants &&
        structWeight <= _shortWordMaxWeight) {
      return min(policy.defaultMaxPathCost, policy.shortWordPathCost);
    }
    if (refConsonants <= policy.mediumWordMaxConsonants ||
        structWeight <= _mediumWordMaxWeight) {
      return min(policy.defaultMaxPathCost, policy.mediumWordPathCost);
    }
    return policy.defaultMaxPathCost;
  }

  _AlignedTraceSummary _tracebackAndVerify({
    required Uint8List bt,
    required int stride,
    required int bestI,
    required int n,
    required String asrText,
    required List<double> asrTimestamps,
    required List<TokenNeuralAcoustics>? asrAcoustics,
    required String fullPhonemes,
    required int refStart,
    required int refEnd,
    required TrackerConfig config,
    required bool isTajweed,
  }) {
    int ci = bestI;
    int cj = n;
    final List<PhonemeGroupAlignment> rawTrace = isTajweed ? [] : const [];
    final List<double> ts = [];

    int matchedConsonants = 0;
    int refConsonants = 0;
    int acousticOverlapSubs = 0;
    int nonAcousticConsSubs = 0;
    int highConfNonAcousticConsSubs = 0;
    int missingBaseConsonants = 0;
    bool deletedFirstConsonant = false;
    bool deletedLastConsonant = false;
    int maddQualityErrors = 0;
    int deletedTerminalMaddChars = 0;
    bool hasTerminalDeletedMadd = false;
    bool seenConsonantAfter = false;

    int firstBaseConsIdx = -1;
    int lastBaseConsIdx = -1;
    for (int j = refStart; j < refEnd; j++) {
      final int c = fullPhonemes.codeUnitAt(j);
      if (!PhoneticCostEngine._isZeroCostMarker(c) &&
          !PhoneticSymbols.isVowelChar(c)) {
        if (firstBaseConsIdx < 0) firstBaseConsIdx = j;
        lastBaseConsIdx = j;
      }
    }

    while (cj > 0) {
      final int gRef = refStart + cj - 1;
      final int refCode = fullPhonemes.codeUnitAt(gRef);
      final bool isZeroMarker = PhoneticCostEngine._isZeroCostMarker(refCode);
      final bool isVowel = PhoneticSymbols.isVowelChar(refCode);
      final bool isRefMadd = PhoneticSymbols.isMaddLongVowel(
        fullPhonemes,
        gRef,
      );
      final bool isRepeatInWord =
          gRef > refStart && refCode == fullPhonemes.codeUnitAt(gRef - 1);

      final bool isBaseConsonant = !isZeroMarker && !isVowel && !isRepeatInWord;
      if (isBaseConsonant) refConsonants++;

      if (ci == 0) {
        if (!seenConsonantAfter && isRefMadd) {
          deletedTerminalMaddChars++;
          if (deletedTerminalMaddChars >= 2) hasTerminalDeletedMadd = true;
        } else if (isBaseConsonant) {
          deletedTerminalMaddChars = 0;
          missingBaseConsonants++;
          if (gRef == firstBaseConsIdx) deletedFirstConsonant = true;
          if (gRef == lastBaseConsIdx) deletedLastConsonant = true;
          seenConsonantAfter = true;
        }
        if (isTajweed) {
          rawTrace.add(
            PhonemeGroupAlignment(
              opType: AlignmentOp.delete,
              refIdx: gRef,
              predIdx: -1,
            ),
          );
        }
        cj--;
        continue;
      }

      final int op = bt[ci * stride + cj];

      if (op == 0) {
        deletedTerminalMaddChars = 0;
        final int asrIdx = ci - 1;
        final int asrCode = asrText.codeUnitAt(asrIdx);
        final TokenNeuralAcoustics? tokenAcoustics =
            (asrAcoustics != null && asrIdx < asrAcoustics.length)
                ? asrAcoustics[asrIdx]
                : null;
        final double subCost = PhoneticCostEngine.getSubstitutionCost(
          asrCode,
          refCode,
          config.acousticConfusionCost,
          asrText,
          asrIdx,
          fullPhonemes,
          gRef,
          tokenAcoustics,
          config.minAltProbThreshold,
        );

        final bool asrMadd = PhoneticSymbols.isMaddLongVowel(asrText, asrIdx);
        if ((isRefMadd || asrMadd) && subCost >= 1.0) {
          maddQualityErrors++;
        }

        if (isBaseConsonant) {
          if (subCost < 1.0) {
            matchedConsonants++;
            if (subCost > 0.0) {
              acousticOverlapSubs++;
            }
          } else {
            nonAcousticConsSubs++;
            final double? conf = tokenAcoustics?.confScore;
            if (conf != null && conf >= config.policy.highConfidenceThreshold) {
              highConfNonAcousticConsSubs++;
            }
          }
          seenConsonantAfter = true;
        }

        if (isTajweed) {
          rawTrace.add(
            PhonemeGroupAlignment(
              opType: subCost == 0.0 ? AlignmentOp.match : AlignmentOp.replace,
              refIdx: gRef,
              predIdx: asrIdx,
            ),
          );
        }
        if (asrIdx < asrTimestamps.length) ts.add(asrTimestamps[asrIdx]);
        ci--;
        cj--;
      } else if (op == 1) {
        if (!seenConsonantAfter && isRefMadd) {
          deletedTerminalMaddChars++;
          if (deletedTerminalMaddChars >= 2) hasTerminalDeletedMadd = true;
        } else {
          deletedTerminalMaddChars = 0;
        }
        if (isBaseConsonant) {
          missingBaseConsonants++;
          if (gRef == firstBaseConsIdx) deletedFirstConsonant = true;
          if (gRef == lastBaseConsIdx) deletedLastConsonant = true;
          seenConsonantAfter = true;
        }
        if (isTajweed) {
          rawTrace.add(
            PhonemeGroupAlignment(
              opType: AlignmentOp.delete,
              refIdx: gRef,
              predIdx: -1,
            ),
          );
        }
        cj--;
      } else {
        deletedTerminalMaddChars = 0;
        if (isTajweed) {
          rawTrace.add(
            PhonemeGroupAlignment(
              opType: AlignmentOp.insert,
              refIdx: gRef,
              predIdx: ci - 1,
            ),
          );
        }
        ci--;
      }
    }

    if (hasTerminalDeletedMadd) {
      maddQualityErrors++;
    }

    return _AlignedTraceSummary(
      matchStart: ci.clamp(0, bestI),
      matchedConsonants: matchedConsonants,
      refConsonants: refConsonants,
      acousticOverlapSubs: acousticOverlapSubs,
      nonAcousticConsSubs: nonAcousticConsSubs,
      highConfNonAcousticConsSubs: highConfNonAcousticConsSubs,
      missingBaseConsonants: missingBaseConsonants,
      deletedFirstConsonant: deletedFirstConsonant,
      deletedLastConsonant: deletedLastConsonant,
      maddQualityErrors: maddQualityErrors,
      timestamps: ts.reversed.toList(),
      trace: isTajweed ? rawTrace.reversed.toList() : const [],
    );
  }

  bool _passesStructuralCheck({
    required _AlignedTraceSummary summary,
    required MatchingPolicy policy,
  }) {
    if (summary.maddQualityErrors > 0) return false;

    final int refCons = summary.refConsonants;
    if (refCons <= 0) return true;

    if (summary.matchStart > 0 && summary.deletedFirstConsonant) {
      return false;
    }

    if (summary.deletedLastConsonant) {
      return false;
    }

    if (policy.enforceAcousticOverlapLimit) {
      final int allowed = refCons >= policy.minConsonantsForAcousticOverlap
          ? policy.maxAcousticOverlapSubs
          : 0;
      if (summary.acousticOverlapSubs > allowed) {
        return false;
      }
    }

    if (summary.highConfNonAcousticConsSubs > 0) return false;

    if (summary.nonAcousticConsSubs > 0) {
      if (!policy.allowSingleLowConfSlipOnLongWords ||
          refCons < policy.minLongWordConsonants ||
          summary.nonAcousticConsSubs > policy.maxLowConfNonAcousticSubs ||
          summary.missingBaseConsonants > 0) {
        return false;
      }
    }

    final int maxMissing = (policy.allowMissingConsonantOnLongWords &&
            refCons >= policy.minLongWordConsonants)
        ? 1
        : 0;
    if (summary.missingBaseConsonants > maxMissing) return false;

    final int minMatched = max(
      1,
      (refCons * policy.minMatchedConsonantRatio).ceil(),
    );
    if (summary.matchedConsonants < minMatched) return false;

    return true;
  }
}

class VariantMatchResult {
  final WordMatchResult result;
  final bool frontierIsNonCanonicalVariant;
  final String? variantForm;
  final List<int>? variantClasses;

  const VariantMatchResult({
    required this.result,
    required this.frontierIsNonCanonicalVariant,
    required this.variantForm,
    required this.variantClasses,
  });
}

class VariantWordMatcher {
  static VariantMatchResult? matchWithForms({
    required QuranDictationMatcher matcher,
    required String fullPhonemes,
    required List<int>? surahCharRuleClasses,
    required List<List<String>>? surahWordForms,
    required TrackerConfig config,
    required bool isTajweed,
    required int wordIndex,
    required String asrText,
    required List<double> asrTimestamps,
    required List<TokenNeuralAcoustics> asrAcoustics,
    required int refStart,
    required int refEnd,
    double? maxCostOverride,
  }) {
    final String canonical = fullPhonemes.substring(
      refStart,
      min(refEnd, fullPhonemes.length),
    );
    final List<String> alts =
        (surahWordForms != null && wordIndex < surahWordForms.length)
            ? surahWordForms[wordIndex]
            : const <String>[];

    final WordMatchResult? primary = matcher.matchWord(
      asrText: asrText,
      asrTimestamps: asrTimestamps,
      fullPhonemes: fullPhonemes,
      refStart: refStart,
      refEnd: refEnd,
      config: config,
      isTajweed: isTajweed,
      asrAcoustics: asrAcoustics,
      maxCostOverride: maxCostOverride,
    );

    if (alts.isEmpty) {
      if (primary == null) return null;
      return VariantMatchResult(
        result: primary,
        frontierIsNonCanonicalVariant: false,
        variantForm: null,
        variantClasses: null,
      );
    }

    final bool canonicalPerfect = primary != null && primary.pathCost <= 1e-6;
    if (canonicalPerfect &&
        (primary.tokensConsumed >= asrText.length ||
            !alts.any((a) => _isVowelLedExtension(canonical, a)))) {
      return VariantMatchResult(
        result: primary,
        frontierIsNonCanonicalVariant: false,
        variantForm: null,
        variantClasses: null,
      );
    }

    WordMatchResult? bestRes = primary;
    String bestForm = canonical;
    bool bestIsCanonical = true;

    for (final alt in alts) {
      if (canonicalPerfect && !_isVowelLedExtension(canonical, alt)) {
        continue;
      }
      final altRes = matcher.matchWord(
        asrText: asrText,
        asrTimestamps: asrTimestamps,
        fullPhonemes: alt,
        refStart: 0,
        refEnd: alt.length,
        config: config,
        isTajweed: isTajweed,
        asrAcoustics: asrAcoustics,
        maxCostOverride: maxCostOverride,
      );
      if (altRes == null || altRes.tokensConsumed <= 0) continue;

      if (bestRes == null) {
        bestRes = altRes;
        bestForm = alt;
        bestIsCanonical = false;
      } else {
        final double costDiff = altRes.pathCost - bestRes.pathCost;
        final bool strictlyBetterCost = costDiff < -0.02;
        final bool comparableCostMoreConsumed = costDiff.abs() <= 0.02 &&
            altRes.tokensConsumed > bestRes.tokensConsumed &&
            (!bestIsCanonical || _isVowelLedExtension(bestForm, alt));
        if (strictlyBetterCost || comparableCostMoreConsumed) {
          bestRes = altRes;
          bestForm = alt;
          bestIsCanonical = false;
        }
      }
    }

    if (bestRes == null) return null;

    bool frontierIsVariant = false;
    List<int>? variantClasses;
    if (!bestIsCanonical && isTajweed) {
      final mapped = mapVariantRuleClasses(
        variant: bestForm,
        canonical: canonical,
        canonicalRefStart: refStart,
        surahCharRuleClasses: surahCharRuleClasses,
      );
      variantClasses = mapped.classes;
      if (bestRes.trace.isNotEmpty) {
        for (int k = bestRes.trace.length - 1; k >= 0; k--) {
          final a = bestRes.trace[k];
          if (a.opType == AlignmentOp.match ||
              a.opType == AlignmentOp.replace) {
            frontierIsVariant = a.refIdx >= 0 &&
                a.refIdx < bestForm.length &&
                mapped.isVariantOnly[a.refIdx];
            break;
          }
        }
      }
    }

    return VariantMatchResult(
      result: bestRes,
      frontierIsNonCanonicalVariant: frontierIsVariant,
      variantForm: bestIsCanonical ? null : bestForm,
      variantClasses: bestIsCanonical ? null : variantClasses,
    );
  }

  static bool _isVowelLedExtension(String shorter, String longer) {
    if (longer.length <= shorter.length || !longer.startsWith(shorter)) {
      return false;
    }
    return PhoneticSymbols.isVowelChar(longer.codeUnitAt(shorter.length));
  }

  static ({List<int> classes, List<bool> isVariantOnly}) mapVariantRuleClasses({
    required String variant,
    required String canonical,
    required int canonicalRefStart,
    required List<int>? surahCharRuleClasses,
  }) {
    final int m = variant.length;
    final int n = canonical.length;
    final classes = List<int>.filled(m, 0);
    final isVariantOnly = List<bool>.filled(m, false);
    if (m == 0 || n == 0) {
      return (classes: classes, isVariantOnly: isVariantOnly);
    }

    final int stride = n + 1;
    final lcs = List<int>.filled((m + 1) * stride, 0);
    for (int i = m - 1; i >= 0; i--) {
      for (int j = n - 1; j >= 0; j--) {
        if (variant.codeUnitAt(i) == canonical.codeUnitAt(j)) {
          lcs[i * stride + j] = 1 + lcs[(i + 1) * stride + j + 1];
        } else {
          final int d = lcs[(i + 1) * stride + j];
          final int r = lcs[i * stride + j + 1];
          lcs[i * stride + j] = d >= r ? d : r;
        }
      }
    }

    for (int i = 0, j = 0; i < m;) {
      if (j < n && variant.codeUnitAt(i) == canonical.codeUnitAt(j)) {
        final int absCanon = canonicalRefStart + j;
        classes[i] = (surahCharRuleClasses != null &&
                absCanon < surahCharRuleClasses.length)
            ? surahCharRuleClasses[absCanon]
            : 0;
        i++;
        j++;
      } else if (j < n && lcs[(i + 1) * stride + j] < lcs[i * stride + j + 1]) {
        j++;
      } else {
        isVariantOnly[i] = true;
        i++;
      }
    }
    return (classes: classes, isVariantOnly: isVariantOnly);
  }
}
