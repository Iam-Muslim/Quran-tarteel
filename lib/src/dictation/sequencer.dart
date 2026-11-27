// lib/src/dictation/sequencer.dart
// Word-committing streaming DTW dictation sequencer and Tajweed frontier controller.

import 'dart:math';

import '../config.dart';
import '../core_types.dart';
import '../reference/zfx_loader.dart';
import '../tajweed/tajweed_engine.dart';
import 'auto_reanchor.dart';
import 'word_matcher.dart';
import 'worker.dart';

/// Stateful word-by-word DTW alignment & Tajweed sequencing engine that consumes
/// streaming ASR phoneme segments and emits committed [WordMatchedEvent]s.
class DictationSequencer {
  static const int _slidingWindowCushion = 20;
  static const int _slidingWindowTrimBatch = 20;

  final void Function(IsolateEvent event) onEvent;

  List<int> wordBoundaries = [];
  String fullPhonemes = '';
  bool isTajweed = false;
  int currentSurahNumber = 0;
  List<int> ayahs = [];
  List<int> wordsInAyah = [];
  List<List<WordTajweedRule>>? surahWordRules;
  List<int>? surahCharRuleClasses;
  List<List<String>>? surahWordForms;

  String currentSegmentAsrText = '';
  List<double> currentSegmentTimestamps = [];
  List<TokenNeuralAcoustics> currentSegmentNeuralAcoustics = [];
  List<int> currentSegmentCharTokenIndices = [];
  List<double> currentSegmentTokenDurations = [];
  List<double> currentSegmentTokenStarts = [];
  List<double> currentSegmentTokenEnds = [];
  int asrCharAnchor = 0;
  int _trimmedOffset = 0;
  int _activeSegmentId = 0;
  int _lastReanchorAttemptOffset = -1;
  int _lastReanchorAttemptLen = -1;

  int targetWordCursor = 0;
  final Set<int> committedGreenWords = {};
  final Set<int> committedRedWords = {};
  bool _isFinal = false;

  final QuranDictationMatcher _matcher = QuranDictationMatcher();
  TrackerConfig config = const TrackerConfig();
  TajweedEngine _tajweedEngine = const TajweedEngine();

  DictationSequencer(this.onEvent);

  void updateConfig(TrackerConfig newConfig) {
    config = newConfig;
    _tajweedEngine = TajweedEngine(
      config: config.tajweed,
      recitationSpeed: config.recitationSpeed,
    );
  }

  void updateTajweedConfig(TajweedConfig newTajweedConfig) {
    config = config.copyWith(tajweed: newTajweedConfig);
    _tajweedEngine = TajweedEngine(
      config: config.tajweed,
      recitationSpeed: config.recitationSpeed,
    );
  }

  bool handleCommand(IsolateCommand command) {
    switch (command) {
      case SetSurahReferenceCommand():
        setSurahReference(command);
      case SyncStreamCommand():
        syncStream(command);
      case JumpToWordCommand():
        jumpToWord(command);
      case SetTajweedModeCommand(:final isTajweed):
        this.isTajweed = isTajweed;
      case UpdateTrackerConfigCommand(:final config):
        updateConfig(config);
      case UpdateTajweedConfigCommand(:final tajweed):
        updateTajweedConfig(tajweed);
      case StopIsolateCommand():
        return false;
    }
    return true;
  }

  int get _wordCount => max(0, wordBoundaries.length - 1);

  void _clearSegmentStream() {
    currentSegmentAsrText = '';
    currentSegmentTimestamps = [];
    currentSegmentNeuralAcoustics = [];
    currentSegmentCharTokenIndices = [];
    currentSegmentTokenDurations = [];
    currentSegmentTokenStarts = [];
    currentSegmentTokenEnds = [];
    asrCharAnchor = 0;
    _trimmedOffset = 0;
    _lastReanchorAttemptOffset = -1;
    _lastReanchorAttemptLen = -1;
  }

  void setSurahReference(SetSurahReferenceCommand cmd) {
    final normalizedPhonemes = cmd.fullPhonemes.replaceAll(' ', '');
    if (cmd.charRuleClasses != null &&
        cmd.charRuleClasses!.length < normalizedPhonemes.length) {
      throw ArgumentError.value(
        cmd.charRuleClasses!.length,
        'charRuleClasses',
        'Must cover fullPhonemes length (${normalizedPhonemes.length}).',
      );
    }

    currentSurahNumber = cmd.surahNumber;
    fullPhonemes = normalizedPhonemes;
    wordBoundaries = cmd.boundaries;
    ayahs = cmd.ayahs;
    wordsInAyah = cmd.wordsInAyah;
    isTajweed = cmd.isTajweed;
    surahWordRules = cmd.wordRules;
    surahCharRuleClasses = cmd.charRuleClasses;
    surahWordForms = cmd.wordForms;

    committedGreenWords.clear();
    committedRedWords.clear();
    _clearSegmentStream();

    targetWordCursor = cmd.startGlobalWord.clamp(0, _wordCount);
  }

  void jumpToWord(JumpToWordCommand cmd) {
    targetWordCursor = cmd.globalWordIndex.clamp(0, _wordCount);
    _clearSegmentStream();
    committedGreenWords.removeWhere((w) => w >= targetWordCursor);
    committedRedWords.removeWhere((w) => w >= targetWordCursor);
  }

  void syncStream(SyncStreamCommand cmd) {
    _isFinal = cmd.isFinal;
    final int incomingEnd = cmd.baseCharOffset + cmd.asrText.length;
    if (cmd.isNewSegment ||
        cmd.segmentId != _activeSegmentId ||
        incomingEnd < _trimmedOffset) {
      _clearSegmentStream();
      _activeSegmentId = cmd.segmentId;
    }

    final int localSkip = max(0, _trimmedOffset - cmd.baseCharOffset);
    currentSegmentAsrText = localSkip < cmd.asrText.length
        ? cmd.asrText.substring(localSkip)
        : '';
    final int tsStart = min(localSkip, cmd.timestamps.length);
    currentSegmentTimestamps = cmd.timestamps.sublist(tsStart);
    final int naStart = min(localSkip, cmd.neuralAcoustics.length);
    currentSegmentNeuralAcoustics = cmd.neuralAcoustics.sublist(naStart);
    final int tiStart = min(localSkip, cmd.charTokenIndices?.length ?? 0);
    currentSegmentCharTokenIndices = cmd.charTokenIndices != null
        ? cmd.charTokenIndices!.sublist(tiStart)
        : [];
    currentSegmentTokenDurations = cmd.tokenDurations ?? [];
    currentSegmentTokenStarts = cmd.tokenStarts ?? [];
    currentSegmentTokenEnds = cmd.tokenEnds ?? [];
    _processSequence();
  }

  void _processSequence() {
    final int wordCount = _wordCount;
    final double skipThreshold =
        min(config.defaultMaxPathCost, config.policy.skipMaxPathCost);

    while (asrCharAnchor < currentSegmentAsrText.length &&
        targetWordCursor < wordCount) {
      final unconsumed = currentSegmentAsrText.substring(asrCharAnchor);
      final int tsStart = min(asrCharAnchor, currentSegmentTimestamps.length);
      final unconsumedTs = currentSegmentTimestamps.sublist(tsStart);
      final int naStart =
          min(asrCharAnchor, currentSegmentNeuralAcoustics.length);
      final unconsumedAcoustics =
          currentSegmentNeuralAcoustics.sublist(naStart);
      final int tiStart =
          min(asrCharAnchor, currentSegmentCharTokenIndices.length);
      final unconsumedTokenIndices =
          currentSegmentCharTokenIndices.sublist(tiStart);

      bool matched = false;

      for (int skip = 0;
          skip <= config.maxSkipWords && targetWordCursor + skip < wordCount;
          skip++) {
        final int w = targetWordCursor + skip;
        final int refStart = wordBoundaries[w];
        final int refEnd = (w + 1 < wordBoundaries.length)
            ? wordBoundaries[w + 1]
            : fullPhonemes.length;

        final matchInfo = VariantWordMatcher.matchWithForms(
          matcher: _matcher,
          fullPhonemes: fullPhonemes,
          surahCharRuleClasses: surahCharRuleClasses,
          surahWordForms: surahWordForms,
          config: config,
          isTajweed: isTajweed,
          wordIndex: w,
          asrText: unconsumed,
          asrTimestamps: unconsumedTs,
          refStart: refStart,
          refEnd: refEnd,
          asrAcoustics: unconsumedAcoustics,
          maxCostOverride: skip > 0 ? skipThreshold : null,
        );

        if (matchInfo == null) continue;
        final result = matchInfo.result;
        if (result.tokensConsumed <= 0) continue;

        if (isTajweed &&
            skip == 0 &&
            !_isFinal &&
            HeldFrontierShield.shouldHold(
              trace: result.trace,
              refPhonemes: matchInfo.variantForm ?? fullPhonemes,
              refEnd: matchInfo.variantForm?.length ?? refEnd,
              charRuleClasses:
                  matchInfo.variantClasses ?? surahCharRuleClasses,
              wordRules: (surahWordRules != null && w < surahWordRules!.length)
                  ? surahWordRules![w]
                  : const [],
              tajweedConfig: config.tajweed,
              recitationSpeed: config.recitationSpeed,
              asrCharAnchor: asrCharAnchor,
              segmentTimestamps: currentSegmentTimestamps,
              segmentCharTokenIndices: currentSegmentCharTokenIndices,
              segmentTokenStarts: currentSegmentTokenStarts,
              segmentTokenEnds: currentSegmentTokenEnds,
              checkFrontier: result.tokensConsumed >= unconsumed.length &&
                  !matchInfo.frontierIsNonCanonicalVariant,
            )) {
          break;
        }

        final bool isLastInAyah = (w + 1 >= wordCount) ||
            (ayahs.isNotEmpty &&
                w + 1 < ayahs.length &&
                ayahs[w] > 0 &&
                ayahs[w + 1] != ayahs[w]);

        if (skip > 0 && !isLastInAyah) {
          final int nextStart = wordBoundaries[w + 1];
          final int nextEnd = (w + 2 < wordBoundaries.length)
              ? wordBoundaries[w + 2]
              : fullPhonemes.length;
          final String nextTail = unconsumed.substring(result.tokensConsumed);

          if (nextTail.isEmpty) continue;

          final int nextConsumedOff = result.tokensConsumed;
          final nextRes = VariantWordMatcher.matchWithForms(
            matcher: _matcher,
            fullPhonemes: fullPhonemes,
            surahCharRuleClasses: surahCharRuleClasses,
            surahWordForms: surahWordForms,
            config: config,
            isTajweed: isTajweed,
            wordIndex: w + 1,
            asrText: nextTail,
            asrTimestamps: nextConsumedOff < unconsumedTs.length
                ? unconsumedTs.sublist(nextConsumedOff)
                : const [],
            refStart: nextStart,
            refEnd: nextEnd,
            asrAcoustics: nextConsumedOff < unconsumedAcoustics.length
                ? unconsumedAcoustics.sublist(nextConsumedOff)
                : const [],
            maxCostOverride: skipThreshold,
          )?.result;

          if (nextRes == null || nextRes.tokensConsumed <= 0) {
            continue;
          }
        }

        for (int s = 0; s < skip; s++) {
          _commitSkipped(targetWordCursor + s);
        }
        _commitGreen(
          w,
          result,
          unconsumed,
          unconsumedTs,
          unconsumedAcoustics,
          unconsumedTokenIndices,
          matchInfo.variantForm,
          matchInfo.variantClasses,
        );

        asrCharAnchor += result.tokensConsumed;
        targetWordCursor = w + 1;
        matched = true;
        _lastReanchorAttemptOffset = -1;
        _lastReanchorAttemptLen = -1;
        break;
      }

      if (!matched) {
        if (config.enableAutoReanchor) {
          final int oldCursor = targetWordCursor;
          _attemptAutoReanchor();
          if (targetWordCursor != oldCursor) {
            continue;
          }
        }
        break;
      }
    }

    if (asrCharAnchor > _slidingWindowCushion + _slidingWindowTrimBatch) {
      final int trim = asrCharAnchor - _slidingWindowCushion;
      _trimmedOffset += trim;
      currentSegmentAsrText = currentSegmentAsrText.substring(trim);
      currentSegmentTimestamps = currentSegmentTimestamps.sublist(
        min(trim, currentSegmentTimestamps.length),
      );
      currentSegmentNeuralAcoustics = currentSegmentNeuralAcoustics.sublist(
        min(trim, currentSegmentNeuralAcoustics.length),
      );
      currentSegmentCharTokenIndices = currentSegmentCharTokenIndices.sublist(
        min(trim, currentSegmentCharTokenIndices.length),
      );
      asrCharAnchor = _slidingWindowCushion;
      onEvent(
        BufferTrimmedEvent(
          segmentEpoch: _activeSegmentId,
          trimmedCharOffset: _trimmedOffset,
        ),
      );
    }
  }

  void _attemptAutoReanchor() {
    if (!config.enableAutoReanchor) return;
    if (wordBoundaries.isEmpty || fullPhonemes.isEmpty) return;

    final int unconsumedLen = currentSegmentAsrText.length - asrCharAnchor;
    if (unconsumedLen < config.reanchorStallThreshold) return;

    final int currentTotalLen = currentSegmentAsrText.length;
    if (_lastReanchorAttemptOffset == asrCharAnchor &&
        _lastReanchorAttemptLen == currentTotalLen) {
      return;
    }
    _lastReanchorAttemptOffset = asrCharAnchor;
    _lastReanchorAttemptLen = currentTotalLen;

    final String rawQuery = currentSegmentAsrText.substring(asrCharAnchor);
    final result = AutoReanchorFinder.findForwardReanchor(
      rawQuery: rawQuery,
      fullPhonemes: fullPhonemes,
      wordBoundaries: wordBoundaries,
      wordCount: _wordCount,
      targetWordCursor: targetWordCursor,
      config: config,
    );

    if (result == null) return;

    final int oldCursor = targetWordCursor;
    asrCharAnchor += result.probeOffset;
    targetWordCursor = result.wordIndex;
    committedGreenWords.removeWhere((w) => w >= targetWordCursor);
    committedRedWords.removeWhere((w) => w >= targetWordCursor);

    final int surah = currentSurahNumber;
    final int ayah =
        (result.wordIndex < ayahs.length) ? ayahs[result.wordIndex] : 0;
    final int wInAyah = (result.wordIndex < wordsInAyah.length)
        ? wordsInAyah[result.wordIndex]
        : 0;

    onEvent(
      AutoReanchorEvent(
        previousWordIndex: oldCursor,
        newWordIndex: result.wordIndex,
        surah: surah,
        ayah: ayah,
        wordInAyah: wInAyah,
        editDistance: result.dist,
        probeOffset: result.probeOffset,
      ),
    );
  }

  void _commitGreen(
    int w,
    WordMatchResult result,
    String slicedAsr,
    List<double> slicedTs, [
    List<TokenNeuralAcoustics>? slicedAcoustics,
    List<int>? slicedTokenIndices,
    String? variantForm,
    List<int>? variantClasses,
  ]) {
    if (committedGreenWords.contains(w)) return;
    committedGreenWords.add(w);
    committedRedWords.remove(w);

    List<ReciterError>? tajweedErrors;
    if (isTajweed &&
        config.tajweed.isAnyCheckEnabled &&
        result.trace.isNotEmpty) {
      final List<WordTajweedRule> expectedWordRules =
          (surahWordRules != null && w < surahWordRules!.length)
              ? surahWordRules![w]
              : const [];

      final List<int>? wordCharClasses =
          variantForm != null ? variantClasses : surahCharRuleClasses;

      final errors = _tajweedEngine.evaluateWordAlignments(
        alignments: result.trace,
        fullPhonemes: variantForm ?? fullPhonemes,
        wordBoundaries:
            variantForm != null ? [0, variantForm.length] : wordBoundaries,
        currentAsrText: slicedAsr,
        trackingTimestamps: slicedTs,
        trackingAcoustics: slicedAcoustics,
        charTokenIndices: slicedTokenIndices,
        tokenDurations: currentSegmentTokenDurations,
        tokenStarts: currentSegmentTokenStarts,
        tokenEnds: currentSegmentTokenEnds,
        startWordId: variantForm != null ? 0 : w,
        nextWordId: variantForm != null ? 1 : w + 1,
        expectedWordRules: expectedWordRules,
        charRuleClasses: wordCharClasses,
      );
      final int errorWordKey = variantForm != null ? 0 : w;
      if (errors.containsKey(errorWordKey)) {
        tajweedErrors = errors[errorWordKey];
      }
    }

    final String refText = _getWordReference(w);
    final int surah = currentSurahNumber;
    final int ayah = (w < ayahs.length) ? ayahs[w] : 0;
    final int wInAyah = (w < wordsInAyah.length) ? wordsInAyah[w] : 0;

    final bool hasTajweedErrors = isTajweed &&
        config.tajweed.isAnyCheckEnabled &&
        tajweedErrors != null &&
        tajweedErrors.isNotEmpty;
    final verdict = hasTajweedErrors
        ? WordEvaluationVerdict.tajweedWarning
        : WordEvaluationVerdict.correct;

    final double startTs =
        result.timestamps.isNotEmpty ? result.timestamps.first : 0.0;
    final double endTs =
        result.timestamps.isNotEmpty ? result.timestamps.last : 0.0;

    onEvent(
      WordMatchedEvent(
        wordId: w,
        surah: surah,
        ayah: ayah,
        wordInAyah: wInAyah,
        verdict: verdict,
        score: max(0.0, 1.0 - result.pathCost),
        cleanAsr: result.cleanAsr,
        expectedPhonemes: refText,
        tajweedErrors: tajweedErrors,
        startTimestamp: startTs,
        endTimestamp: endTs,
      ),
    );
  }

  void _commitSkipped(int w) {
    if (committedRedWords.contains(w) || committedGreenWords.contains(w)) {
      return;
    }
    committedRedWords.add(w);

    final String refText = _getWordReference(w);
    final int surah = currentSurahNumber;
    final int ayah = (w < ayahs.length) ? ayahs[w] : 0;
    final int wInAyah = (w < wordsInAyah.length) ? wordsInAyah[w] : 0;

    onEvent(
      WordMatchedEvent(
        wordId: w,
        surah: surah,
        ayah: ayah,
        wordInAyah: wInAyah,
        verdict: WordEvaluationVerdict.skipped,
        score: 0.0,
        cleanAsr: '',
        expectedPhonemes: refText,
        tajweedErrors: [
          ReciterError(
            errorType: ErrorCategory.normal,
            speechErrorType: SpeechErrorType.delete,
            expectedPh: refText,
            predictedPh: '',
          ),
        ],
      ),
    );
  }

  String _getWordReference(int w) {
    if (w < 0 || w >= _wordCount) return '';
    final start = wordBoundaries[w];
    final end = (w + 1 < wordBoundaries.length)
        ? wordBoundaries[w + 1]
        : fullPhonemes.length;
    return fullPhonemes.substring(start, min(end, fullPhonemes.length));
  }
}
