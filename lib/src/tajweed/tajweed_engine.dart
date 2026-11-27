// lib/src/tajweed/tajweed_engine.dart
// Deterministic Tajweed grading, directional CTC blank attribution, and frontier holding shield.

import 'dart:math';

import '../config.dart';
import '../core_types.dart';
import '../reference/zfx_loader.dart';
import 'tajweed_types.dart';

export 'tajweed_types.dart';

/// Computes held acoustic duration for Shaddah, Ghunnah, Madd, and plain spans
/// using Layer 15 CTC `log_probs` token boundaries and directional blank attribution.
class SpanDurationCalculator {
  static const double minBlankGapSeconds = 0.040;
  static const double defaultMaxGapSeconds = 1.25;
  static const double longMaddMaxGapSeconds = 2.50;

  static double? measure({
    required PhoneticSpan span,
    PhoneticSpan? prevSpan,
    PhoneticSpan? nextSpan,
    required Set<int> touchedTokens,
    required int wordRefEnd,
    required List<double>? tokenDurations,
    required List<double>? tokenStarts,
    required List<double>? tokenEnds,
    required List<double> trackingTimestamps,
    RecitationSpeed speed = RecitationSpeed.normal,
  }) {
    if (tokenDurations == null) return null;
    if (touchedTokens.isEmpty) return 0.0;

    if (span.isPlainLetter) {
      final int lastT = touchedTokens.reduce(max);
      final bool isWordEnd = span.refEnd == wordRefEnd;
      final bool nextIsPlain =
          !isWordEnd && (nextSpan?.isPlainLetter ?? false);
      double maxTokenDur = 0.0;
      for (final t in touchedTokens) {
        if (t < 0 || t >= tokenDurations.length) continue;
        double d = tokenDurations[t];
        if (t < lastT || nextIsPlain) {
          final gap = _continuationGap(
            lastT: t,
            tokenStarts: tokenStarts,
            tokenEnds: tokenEnds,
            trackingTimestamps: trackingTimestamps,
            maxGap: defaultMaxGapSeconds,
          );
          if (gap != null) d += gap;
        }
        if (d > maxTokenDur) maxTokenDur = d;
      }
      return maxTokenDur;
    }

    double baseDuration = 0.0;
    for (final t in touchedTokens) {
      if (t >= 0 && t < tokenDurations.length) {
        baseDuration += tokenDurations[t];
      }
    }

    if (!span.isHeldDurationRule || span.rule == null) {
      return baseDuration;
    }

    final int firstT = touchedTokens.reduce(min);
    final int lastT = touchedTokens.reduce(max);
    final bool isWordEnd = span.refEnd == wordRefEnd;

    if (span.isMadd) {
      final int ruleId = span.rule!.ruleId;
      final bool is6HarakatCapable = ruleId == 4 ||
          ruleId == 5 ||
          ruleId == 6 ||
          ruleId == 7 ||
          span.rule!.goldenLen >= 6;
      final double maxGap =
          is6HarakatCapable ? longMaddMaxGapSeconds : defaultMaxGapSeconds;

      final double? rawAfter = _continuationGap(
        lastT: lastT,
        tokenStarts: tokenStarts,
        tokenEnds: tokenEnds,
        trackingTimestamps: trackingTimestamps,
        maxGap: maxGap,
        nullOnPause: isWordEnd,
      );
      if (rawAfter == null) return null;
      return baseDuration +
          _shareAfterGap(
            rawGap: rawAfter,
            leftSpan: span,
            rightSpan: nextSpan,
            speed: speed,
          );
    }

    final double rawBefore = _closureGap(
      firstT: firstT,
      tokenStarts: tokenStarts,
      tokenEnds: tokenEnds,
    );
    final double? rawAfter = _continuationGap(
      lastT: lastT,
      tokenStarts: tokenStarts,
      tokenEnds: tokenEnds,
      trackingTimestamps: trackingTimestamps,
      maxGap: defaultMaxGapSeconds,
      nullOnPause: isWordEnd,
    );
    if (rawAfter == null) return null;

    final double beforeShare = _shareBeforeGap(
      rawGap: rawBefore,
      leftSpan: prevSpan,
      rightSpan: span,
      speed: speed,
    );
    final double afterShare = _shareAfterGap(
      rawGap: rawAfter,
      leftSpan: span,
      rightSpan: nextSpan,
      speed: speed,
    );
    return baseDuration + min(defaultMaxGapSeconds, beforeShare + afterShare);
  }

  static double _shareAfterGap({
    required double rawGap,
    required PhoneticSpan leftSpan,
    required PhoneticSpan? rightSpan,
    required RecitationSpeed speed,
  }) {
    if (rawGap <= 0.0 ||
        rightSpan == null ||
        !(rightSpan.isShaddah || rightSpan.isGhunnah) ||
        leftSpan.rule == null ||
        rightSpan.rule == null) {
      return rawGap;
    }
    final double leftT = leftSpan.rule!.getRequiredDuration(speed);
    final double rightT = rightSpan.rule!.getRequiredDuration(speed);
    final double total = leftT + rightT;
    return total > 0.0 ? rawGap * (leftT / total) : rawGap;
  }

  static double _shareBeforeGap({
    required double rawGap,
    required PhoneticSpan? leftSpan,
    required PhoneticSpan rightSpan,
    required RecitationSpeed speed,
  }) {
    if (rawGap <= 0.0 ||
        leftSpan == null ||
        !leftSpan.isHeldDurationRule ||
        leftSpan.rule == null ||
        rightSpan.rule == null) {
      return rawGap;
    }
    final double leftT = leftSpan.rule!.getRequiredDuration(speed);
    final double rightT = rightSpan.rule!.getRequiredDuration(speed);
    final double total = leftT + rightT;
    return total > 0.0 ? rawGap * (rightT / total) : rawGap;
  }

  static double _closureGap({
    required int firstT,
    required List<double>? tokenStarts,
    required List<double>? tokenEnds,
  }) {
    if (firstT <= 0 ||
        tokenStarts == null ||
        tokenEnds == null ||
        firstT >= tokenStarts.length ||
        (firstT - 1) >= tokenEnds.length) {
      return 0.0;
    }
    final double gap = tokenStarts[firstT] - tokenEnds[firstT - 1];
    return (gap >= minBlankGapSeconds && gap < defaultMaxGapSeconds) ? gap : 0.0;
  }

  static double? _continuationGap({
    required int lastT,
    required List<double>? tokenStarts,
    required List<double>? tokenEnds,
    required List<double> trackingTimestamps,
    double maxGap = defaultMaxGapSeconds,
    bool nullOnPause = false,
  }) {
    if (lastT < 0 || tokenEnds == null || lastT >= tokenEnds.length) {
      return 0.0;
    }
    double gap = 0.0;
    if (tokenStarts != null && (lastT + 1) < tokenStarts.length) {
      gap = tokenStarts[lastT + 1] - tokenEnds[lastT];
    } else if (trackingTimestamps.isNotEmpty) {
      gap = trackingTimestamps.last - tokenEnds[lastT];
    }
    if (gap >= maxGap && nullOnPause) {
      return null;
    }
    return (gap >= minBlankGapSeconds && gap < maxGap) ? gap : 0.0;
  }
}

/// Streaming commit shield for held Tajweed sounds (Madd, Ghunnah, Shaddah),
/// Qalqalah release windows, and deleted terminal vowels.
class HeldFrontierShield {
  static const double _qalqalahPostBurstSeconds = 0.360;
  static const double _terminalVowelHoldSeconds = 0.300;

  static ({double start, double end}) _tokenBoundsForPred({
    required int globalPred,
    required List<double> segmentTimestamps,
    required List<int> segmentCharTokenIndices,
    required List<double> segmentTokenStarts,
    required List<double> segmentTokenEnds,
  }) {
    double startTs = -1.0;
    double endTs = -1.0;
    if (globalPred >= 0 && globalPred < segmentCharTokenIndices.length) {
      final int tokIdx = segmentCharTokenIndices[globalPred];
      if (tokIdx >= 0 && tokIdx < segmentTokenStarts.length) {
        startTs = segmentTokenStarts[tokIdx];
      }
      if (tokIdx >= 0 && tokIdx < segmentTokenEnds.length) {
        endTs = segmentTokenEnds[tokIdx];
      }
    }
    if (globalPred >= 0 && globalPred < segmentTimestamps.length) {
      if (startTs < 0.0) startTs = segmentTimestamps[globalPred];
      if (endTs < 0.0) endTs = segmentTimestamps[globalPred];
    }
    return (start: startTs, end: endTs);
  }

  static bool shouldHold({
    required List<PhonemeGroupAlignment> trace,
    required String refPhonemes,
    required int refEnd,
    required List<int>? charRuleClasses,
    required List<WordTajweedRule> wordRules,
    required TajweedConfig tajweedConfig,
    RecitationSpeed recitationSpeed = RecitationSpeed.normal,
    required int asrCharAnchor,
    required List<double> segmentTimestamps,
    required List<int> segmentCharTokenIndices,
    required List<double> segmentTokenStarts,
    required List<double> segmentTokenEnds,
    bool checkFrontier = true,
  }) {
    if (refPhonemes.isEmpty || trace.isEmpty) return false;

    final double latestTs = segmentTimestamps.isNotEmpty
        ? segmentTimestamps.last
        : (segmentTokenEnds.isNotEmpty ? segmentTokenEnds.last : 0.0);
    final int limit = min(refEnd, refPhonemes.length);

    if (tajweedConfig.checkQalqalah && segmentTokenEnds.isNotEmpty) {
      for (final a in trace) {
        if (a.predIdx < 0 ||
            a.opType == AlignmentOp.delete ||
            a.opType == AlignmentOp.insert) {
          continue;
        }
        final int r = a.refIdx;
        if (r < 0 || r >= limit) continue;
        final int cls = (charRuleClasses != null && r < charRuleClasses.length)
            ? charRuleClasses[r]
            : 0;
        if (cls <= 0 || (cls - 1) >= wordRules.length) continue;
        final rule = wordRules[cls - 1];
        if (rule.ruleId != 8 && !rule.hasQalqalah) continue;

        int spanEnd = r + 1;
        while (spanEnd < limit &&
            spanEnd < charRuleClasses!.length &&
            charRuleClasses[spanEnd] == cls) {
          spanEnd++;
        }
        if (spanEnd < limit &&
            PhoneticSymbols.isVowelChar(refPhonemes.codeUnitAt(spanEnd))) {
          continue;
        }

        final bounds = _tokenBoundsForPred(
          globalPred: asrCharAnchor + a.predIdx,
          segmentTimestamps: segmentTimestamps,
          segmentCharTokenIndices: segmentCharTokenIndices,
          segmentTokenStarts: segmentTokenStarts,
          segmentTokenEnds: segmentTokenEnds,
        );
        if (bounds.end >= 0.0 &&
            (latestTs - bounds.end) < _qalqalahPostBurstSeconds) {
          return true;
        }
      }
    }

    if (!checkFrontier) return false;

    int lastMatchedRef = -1;
    int lastMatchedPred = -1;
    for (int k = trace.length - 1; k >= 0; k--) {
      final a = trace[k];
      if (a.predIdx >= 0 && a.opType != AlignmentOp.delete) {
        lastMatchedRef = a.refIdx;
        lastMatchedPred = a.predIdx;
        break;
      }
    }
    if (lastMatchedRef < 0 || lastMatchedPred < 0) return false;

    int ruleId = 0;
    num goldenLen = 0;
    if (charRuleClasses != null && lastMatchedRef < charRuleClasses.length) {
      final int cls = charRuleClasses[lastMatchedRef];
      if (cls > 0 && (cls - 1) < wordRules.length) {
        ruleId = wordRules[cls - 1].ruleId;
        goldenLen = wordRules[cls - 1].goldenLen;
      }
    }

    final ruleType = TajweedRuleType.fromId(ruleId);
    final bool isHeldRule = (ruleType.isMadd && tajweedConfig.checkMadd) ||
        (ruleType == TajweedRuleType.shaddah && tajweedConfig.checkShaddah) ||
        (ruleType == TajweedRuleType.ghunnah && tajweedConfig.checkGhunnah);
    final bool hasDeletedTerminalVowel = !isHeldRule &&
        tajweedConfig.checkTashkeel &&
        trace.last.opType == AlignmentOp.delete &&
        PhoneticSymbols.isTashkeelChar(refPhonemes, refEnd - 1);

    if (!isHeldRule && !hasDeletedTerminalVowel) return false;

    final bounds = _tokenBoundsForPred(
      globalPred: asrCharAnchor + lastMatchedPred,
      segmentTimestamps: segmentTimestamps,
      segmentCharTokenIndices: segmentCharTokenIndices,
      segmentTokenStarts: segmentTokenStarts,
      segmentTokenEnds: segmentTokenEnds,
    );
    if (bounds.start < 0.0) return true;

    final double holdWindow = hasDeletedTerminalVowel
        ? _terminalVowelHoldSeconds
        : min(
            2.0,
            max(
              TajweedRuleFactory.instantiateFromId(
                    ruleId,
                    goldenLen,
                    recitationSpeed,
                  ).getRequiredDuration(recitationSpeed) +
                  0.15,
              0.45,
            ),
          );
    return (latestTs - bounds.start) < holdWindow;
  }
}

class TajweedEngine {
  final TajweedConfig config;
  final RecitationSpeed recitationSpeed;

  const TajweedEngine({
    this.config = const TajweedConfig(),
    this.recitationSpeed = RecitationSpeed.normal,
  });

  List<PhoneticSpan> buildWordSpans({
    required String fullPhonemes,
    required int wordRefStart,
    required int wordRefEnd,
    required List<WordTajweedRule> expectedWordRules,
    List<int>? charRuleClasses,
  }) {
    final List<PhoneticSpan> spans = [];
    int cursor = wordRefStart;

    while (cursor < wordRefEnd) {
      final int cls =
          (charRuleClasses != null && cursor < charRuleClasses.length)
              ? charRuleClasses[cursor]
              : 0;

      if (cls > 0) {
        int end = cursor;
        while (end < wordRefEnd &&
            end < charRuleClasses!.length &&
            charRuleClasses[end] == cls) {
          end++;
        }
        final String refText = fullPhonemes.substring(cursor, end);
        final WordTajweedRule? wordRule = (cls - 1 < expectedWordRules.length)
            ? expectedWordRules[cls - 1]
            : null;
        final TajweedRule? rule = wordRule != null
            ? TajweedRuleFactory.instantiate(wordRule, recitationSpeed)
            : null;
        final int ruleId = wordRule?.ruleId ?? 0;

        final bool rawQalqalah =
            ruleId == 8 || (wordRule?.hasQalqalah ?? false);
        final bool suppressedByWaslVowel = rawQalqalah &&
            end < wordRefEnd &&
            end < fullPhonemes.length &&
            PhoneticSymbols.isVowelChar(fullPhonemes.codeUnitAt(end));

        final bool isActiveQalqalah = rawQalqalah && !suppressedByWaslVowel;
        spans.add(
          PhoneticSpan(
            refStart: cursor,
            refEnd: end,
            refText: refText,
            baseChar: refText.isNotEmpty ? refText[0] : '',
            ruleType: rule?.ruleType ?? TajweedRuleType.fromId(ruleId),
            rule: rule,
            isQalqalah: isActiveQalqalah,
            qalqalahLevel:
                isActiveQalqalah ? (wordRule?.qalqalahExpected ?? 0) : 0,
          ),
        );
        cursor = end;
        continue;
      }

      final String ch = fullPhonemes[cursor];
      int end = cursor + 1;
      while (end < wordRefEnd &&
          (charRuleClasses == null ||
              end >= charRuleClasses.length ||
              charRuleClasses[end] == 0) &&
          PhoneticSymbols.isVowelChar(fullPhonemes.codeUnitAt(end))) {
        end++;
      }

      spans.add(
        PhoneticSpan(
          refStart: cursor,
          refEnd: end,
          refText: fullPhonemes.substring(cursor, end),
          baseChar: ch,
          ruleType: TajweedRuleType.plainLetter,
          rule: const PlainLetterRule(),
        ),
      );
      cursor = end;
    }

    return spans;
  }

  Map<int, List<ReciterError>> evaluateWordAlignments({
    required List<PhonemeGroupAlignment> alignments,
    required String fullPhonemes,
    required List<int> wordBoundaries,
    required String currentAsrText,
    required List<double> trackingTimestamps,
    List<TokenNeuralAcoustics>? trackingAcoustics,
    List<int>? charTokenIndices,
    List<double>? tokenDurations,
    List<double>? tokenStarts,
    List<double>? tokenEnds,
    required int startWordId,
    required int nextWordId,
    List<WordTajweedRule> expectedWordRules = const [],
    List<int>? charRuleClasses,
  }) {
    if (!config.isAnyCheckEnabled) return const {};
    final Map<int, List<ReciterError>> errorsByWord = {};

    for (int w = startWordId; w < nextWordId; w++) {
      if (w >= wordBoundaries.length) break;

      final int wordRefStart = wordBoundaries[w];
      final int wordRefEnd = (w + 1 < wordBoundaries.length)
          ? wordBoundaries[w + 1]
          : fullPhonemes.length;

      final spans = buildWordSpans(
        fullPhonemes: fullPhonemes,
        wordRefStart: wordRefStart,
        wordRefEnd: wordRefEnd,
        expectedWordRules: expectedWordRules,
        charRuleClasses: charRuleClasses,
      );

      final List<ReciterError> wordErrors = [];
      for (int sIdx = 0; sIdx < spans.length; sIdx++) {
        final span = spans[sIdx];
        final PhoneticSpan? prevSpan = sIdx > 0 ? spans[sIdx - 1] : null;
        final PhoneticSpan? nextSpan =
            sIdx + 1 < spans.length ? spans[sIdx + 1] : null;
        final spanAlignments = alignments
            .where((a) => a.refIdx >= span.refStart && a.refIdx < span.refEnd)
            .toList();
        if (spanAlignments.isEmpty) continue;

        final asr = _aggregateSpanAsr(
          spanAlignments: spanAlignments,
          currentAsrText: currentAsrText,
          trackingAcoustics: trackingAcoustics,
          charTokenIndices: charTokenIndices,
        );

        final double? spanDuration = SpanDurationCalculator.measure(
          span: span,
          prevSpan: prevSpan,
          nextSpan: nextSpan,
          touchedTokens: asr.touchedTokens,
          wordRefEnd: wordRefEnd,
          tokenDurations: tokenDurations,
          tokenStarts: tokenStarts,
          tokenEnds: tokenEnds,
          trackingTimestamps: trackingTimestamps,
          speed: recitationSpeed,
        );

        wordErrors.addAll(
          evaluateSpan(
            span: span,
            predText: asr.predText,
            spanDuration: spanDuration,
            spanAcoustics: asr.acoustics,
            wordRefEnd: wordRefEnd,
          ),
        );
      }

      if (wordErrors.isNotEmpty) {
        errorsByWord[w] = _prioritizeAndDeduplicate(wordErrors);
      }
    }

    return errorsByWord;
  }

  List<ReciterError> evaluateSpan({
    required PhoneticSpan span,
    required String predText,
    required double? spanDuration,
    TokenNeuralAcoustics spanAcoustics = const TokenNeuralAcoustics(),
    required int wordRefEnd,
  }) {
    if (!config.isAnyCheckEnabled) return const [];
    final List<ReciterError> errors = [];

    final bool isVowelOnlySpan = span.baseChar.isNotEmpty &&
        PhoneticSymbols.isVowelChar(span.baseChar.codeUnitAt(0)) &&
        !span.isTajweedSite;

    if (!isVowelOnlySpan && span.refText.isNotEmpty) {
      final String refCons = _uniqueConsonants(span.refText);
      final String predCons = _uniqueConsonants(predText);
      final bool soundMissing =
          predText.isEmpty || (refCons.isNotEmpty && predCons.isEmpty);
      final letterErr = _gradeLetter(
        span: span,
        predText: predText,
        refCons: refCons,
        predCons: predCons,
        soundMissing: soundMissing,
      );
      if (letterErr != null) {
        errors.add(letterErr);
        return errors;
      }
      if (soundMissing) return errors;
    }

    final bool checkDuration = (span.isMadd && config.checkMadd) ||
        (span.isGhunnah && config.checkGhunnah) ||
        (span.isShaddah && config.checkShaddah) ||
        (span.isPlainLetter && config.checkPlainLetters);
    if (checkDuration && spanDuration != null && span.rule != null) {
      final durErr = _gradeDuration(
        span: span,
        rule: span.rule!,
        predText: predText,
        spanDuration: spanDuration,
      );
      if (durErr != null) errors.add(durErr);
      if (span.isMadd) {
        if (config.checkTashkeel) {
          final vowelErr = _gradeVowels(
            span: span,
            predText: predText,
            wordRefEnd: wordRefEnd,
          );
          if (vowelErr != null) errors.add(vowelErr);
        }
        return errors;
      }
    }

    if (span.isQalqalah && config.checkQalqalah) {
      final qalErr = _gradeQalqalah(
        span: span,
        predText: predText,
        spanAcoustics: spanAcoustics,
      );
      if (qalErr != null) errors.add(qalErr);
    }

    if (config.checkTashkeel) {
      final vowelErr = _gradeVowels(
        span: span,
        predText: predText,
        wordRefEnd: wordRefEnd,
      );
      if (vowelErr != null) errors.add(vowelErr);
    }

    return errors;
  }

  bool _isRuleToggleEnabled(PhoneticSpan span) =>
      (span.isMadd && config.checkMadd) ||
      (span.isGhunnah && config.checkGhunnah) ||
      (span.isShaddah && config.checkShaddah) ||
      (span.isQalqalah && config.checkQalqalah);

  ReciterError? _gradeLetter({
    required PhoneticSpan span,
    required String predText,
    required String refCons,
    required String predCons,
    required bool soundMissing,
  }) {
    if (soundMissing) {
      if (span.isTajweedSite && _isRuleToggleEnabled(span)) {
        final rule = (span.isQalqalah && !config.checkShaddah)
            ? QalqalahRule(span.qalqalahLevel)
            : span.rule!;
        return ReciterError(
          errorType: ErrorCategory.tajweed,
          speechErrorType: SpeechErrorType.delete,
          durationStatus: TajweedDurationStatus.underheld,
          expectedPh: span.refText,
          predictedPh: predText,
          expectedRule: rule,
          expectedDuration: rule.getRequiredDuration(recitationSpeed),
          actualDuration: 0.0,
        );
      }
      if (config.checkLetterSwap && refCons.isNotEmpty) {
        return ReciterError(
          errorType: ErrorCategory.normal,
          speechErrorType: SpeechErrorType.delete,
          expectedPh: span.refText,
          predictedPh: predText,
        );
      }
      return null;
    }

    if (!config.checkLetterSwap || refCons.isEmpty) return null;

    final int compareLen = min(refCons.length, predCons.length);
    for (int i = 0; i < compareLen; i++) {
      if (refCons.codeUnitAt(i) != predCons.codeUnitAt(i)) {
        return ReciterError(
          errorType: ErrorCategory.normal,
          speechErrorType: SpeechErrorType.replace,
          expectedPh: span.refText,
          predictedPh: predText,
        );
      }
    }
    return null;
  }

  ReciterError? _gradeDuration({
    required PhoneticSpan span,
    required TajweedRule rule,
    required String predText,
    required double spanDuration,
  }) {
    final speed = recitationSpeed;
    final double req = rule.getRequiredDuration(speed);
    final TajweedDurationStatus status =
        rule.checkDurationStatus(spanDuration, speed);

    if (status == TajweedDurationStatus.underheld ||
        status == TajweedDurationStatus.overheld) {
      return ReciterError(
        errorType: ErrorCategory.tajweed,
        speechErrorType: SpeechErrorType.replace,
        durationStatus: status,
        expectedPh: span.refText,
        predictedPh: predText,
        expectedRule: rule,
        expectedDuration: req,
        actualDuration: spanDuration,
      );
    }
    return null;
  }

  ReciterError? _gradeQalqalah({
    required PhoneticSpan span,
    required String predText,
    required TokenNeuralAcoustics spanAcoustics,
  }) {
    final TajweedRule rule = span.rule is QalqalahRule
        ? span.rule!
        : QalqalahRule(span.qalqalahLevel);
    final double? effectiveTau = config.qalqalahTau;
    if (effectiveTau == null) {
      throw const QuranTarteelException(
        QuranTarteelErrorCode.missingCalibrationThreshold,
      );
    }

    if (spanAcoustics.qalqalahScore < effectiveTau) {
      return ReciterError(
        errorType: ErrorCategory.tajweed,
        speechErrorType: SpeechErrorType.replace,
        durationStatus: TajweedDurationStatus.underheld,
        expectedPh: span.refText,
        predictedPh: predText,
        expectedRule: rule,
      );
    }
    return null;
  }

  ReciterError? _gradeVowels({
    required PhoneticSpan span,
    required String predText,
    required int wordRefEnd,
  }) {
    final String refVowels = _collapsedVowels(span.refText);
    final String predVowels = _collapsedVowels(predText);
    if (refVowels.isEmpty && predVowels.isEmpty) return null;

    final bool isTerminalDrop =
        span.refEnd == wordRefEnd && predVowels.isEmpty;
    if (!isTerminalDrop && refVowels != predVowels) {
      return ReciterError(
        errorType: ErrorCategory.tashkeel,
        speechErrorType: predVowels.isEmpty
            ? SpeechErrorType.delete
            : SpeechErrorType.replace,
        expectedPh: span.refText,
        predictedPh: predText,
      );
    }
    return null;
  }

  static String _uniqueConsonants(String text) {
    final sb = StringBuffer();
    int lastCode = -1;
    for (int i = 0; i < text.length; i++) {
      final int code = text.codeUnitAt(i);
      if (PhoneticSymbols.isVowelChar(code) ||
          code == PhoneticSymbols.wordBarCodeUnit) {
        continue;
      }
      if (code == lastCode) continue;
      sb.writeCharCode(code);
      lastCode = code;
    }
    return sb.toString();
  }

  static String _collapsedVowels(String text) {
    final sb = StringBuffer();
    int lastCode = -1;
    for (int i = 0; i < text.length; i++) {
      final int code = text.codeUnitAt(i);
      if (!PhoneticSymbols.isVowelChar(code)) continue;
      if (code == lastCode) continue;
      sb.writeCharCode(code);
      lastCode = code;
    }
    return sb.toString();
  }

  static _AggregatedSpan _aggregateSpanAsr({
    required List<PhonemeGroupAlignment> spanAlignments,
    required String currentAsrText,
    required List<TokenNeuralAcoustics>? trackingAcoustics,
    required List<int>? charTokenIndices,
  }) {
    final predBuf = StringBuffer();
    final usedPredIndices = <int>{};
    final touchedTokens = <int>{};
    double maxQalqalah = 0.0;
    double sumConf = 0.0;
    int confCount = 0;

    for (final a in spanAlignments) {
      if (a.opType == AlignmentOp.insert) continue;
      final int predIdx = a.predIdx;
      if (predIdx < 0 || predIdx >= currentAsrText.length) continue;

      predBuf.write(currentAsrText[predIdx]);
      if (usedPredIndices.add(predIdx)) {
        if (charTokenIndices != null && predIdx < charTokenIndices.length) {
          touchedTokens.add(charTokenIndices[predIdx]);
        }
        if (trackingAcoustics != null && predIdx < trackingAcoustics.length) {
          final ac = trackingAcoustics[predIdx];
          if (ac.qalqalahScore > maxQalqalah) {
            maxQalqalah = ac.qalqalahScore;
          }
          if (ac.confScore != null) {
            sumConf += ac.confScore!;
            confCount++;
          }
        }
      }
    }

    return _AggregatedSpan(
      predText: predBuf.toString(),
      touchedTokens: touchedTokens,
      acoustics: (usedPredIndices.isNotEmpty)
          ? TokenNeuralAcoustics(
              qalqalahScore: maxQalqalah,
              confScore: confCount > 0 ? sumConf / confCount : null,
            )
          : const TokenNeuralAcoustics(),
    );
  }

  static List<ReciterError> _prioritizeAndDeduplicate(
    List<ReciterError> wordErrors,
  ) {
    wordErrors.sort((a, b) => a.priority.compareTo(b.priority));
    final deduplicated = <ReciterError>[];
    final seenKeys = <String>{};
    for (final e in wordErrors) {
      final key =
          '${e.errorType.index}_${e.expectedRule?.ruleType.index ?? -1}_${e.expectedPh}';
      if (seenKeys.add(key)) {
        deduplicated.add(e);
      }
    }
    return deduplicated;
  }
}

class _AggregatedSpan {
  final String predText;
  final Set<int> touchedTokens;
  final TokenNeuralAcoustics acoustics;

  const _AggregatedSpan({
    required this.predText,
    required this.touchedTokens,
    required this.acoustics,
  });
}
