// lib/scoring.dart
// Pure-Dart Quran recitation alignment, deterministic Tajweed grading, and phonetic search.

import 'dart:async';

import 'src/config.dart';
import 'src/core_types.dart';
import 'src/dictation/transcript_normalizer.dart';
import 'src/dictation/worker.dart';
import 'src/reference/quran_repository.dart';
import 'src/reference/zfx_loader.dart';

export 'src/config.dart'
    show
        RecitationSpeed,
        TajweedConfig,
        MatchingStrictness,
        MatchingPolicy,
        ReanchorPolicy,
        TrackerConfig;
export 'src/core_types.dart'
    show
        QuranTarteelErrorCode,
        QuranTarteelException,
        QuranCoordinate,
        PhoneticSymbols,
        TokenNeuralAcoustics,
        TranscriptionResult,
        PhonemeVocabulary;
export 'src/dictation/worker.dart'
    show WordEvaluationVerdict, WordMatchedEvent, AutoReanchorEvent;
export 'src/reference/quran_repository.dart' show QuranRepository;
export 'src/reference/zfx_loader.dart'
    show WordTajweedRule, ComposedWord, QuranVerse, ContinuousQuranWord;
export 'src/search/voice_search.dart'
    show AyahSearchMatch, VoiceSearchResult, VoiceSearchController;
export 'src/tajweed/tajweed_types.dart'
    show
        TajweedRuleType,
        TajweedDurationStatus,
        AcousticThreshold,
        TajweedRule,
        MaddRule,
        MushaddadGhunnahRule,
        ShaddahRule,
        QalqalahRule,
        PlainLetterRule,
        TajweedRuleFactory,
        ErrorCategory,
        SpeechErrorType,
        AlignmentOp,
        PhonemeGroupAlignment,
        PhoneticSpan,
        ReciterError;

/// Standalone Quran recitation evaluator and scoring system.
///
/// Consumes [TranscriptionResult]s (from `quranlab_tajweedformer` via
/// `TajweedTakeDecoder` or any compatible ASR source), aligns phonemes using
/// DTW in a background isolate, evaluates deterministic Tajweed rules, and emits
/// [WordMatchedEvent] and [AutoReanchorEvent] streams.
class QuranScorer {
  final QuranRepository repository;
  final PhonemeAlignmentIsolate _isolate = PhonemeAlignmentIsolate();
  late final TranscriptNormalizer _transcriptNormalizer;

  TrackerConfig _config;
  bool _isTajweed;
  bool _isInitialized = false;
  bool _isDisposed = false;
  int _targetSurah = 0;
  int? _lastStreamEpoch;
  bool _pendingNewSegment = false;
  int _currentSegmentId = 0;
  int _confirmedTrimCharOffset = 0;

  StreamSubscription<WordMatchedEvent>? _wordSub;
  StreamSubscription<AutoReanchorEvent>? _reanchorSub;
  StreamSubscription<BufferTrimmedEvent>? _trimSub;

  final StreamController<WordMatchedEvent> _wordEventController =
      StreamController<WordMatchedEvent>.broadcast();
  final StreamController<AutoReanchorEvent> _autoReanchorController =
      StreamController<AutoReanchorEvent>.broadcast();

  /// Broadcast stream of word-level verdicts (`correct`, `tajweedWarning`, `skipped`).
  Stream<WordMatchedEvent> get onWordEvaluated => _wordEventController.stream;

  /// Broadcast stream of unambiguous forward auto-reanchor jump events.
  Stream<AutoReanchorEvent> get onAutoReanchored =>
      _autoReanchorController.stream;

  TrackerConfig get config => _config;
  TajweedConfig get tajweedConfig => _config.tajweed;
  int get targetSurah => _targetSurah;
  bool get isTajweed => _isTajweed;
  bool get isInitialized => _isInitialized;
  bool get isDisposed => _isDisposed;

  QuranScorer({
    required this.repository,
    TrackerConfig config = const TrackerConfig(),
    bool isTajweed = true,
  })  : _config = config,
        _isTajweed = isTajweed {
    _transcriptNormalizer = TranscriptNormalizer(config: _config);
  }

  void _requireActive() {
    if (_isDisposed) {
      throw const QuranTarteelException(QuranTarteelErrorCode.disposed);
    }
  }

  /// Starts the background phoneme alignment isolate.
  ///
  /// [repository] must already be loaded with `expected_tj3.zfx` bytes and
  /// a [PhonemeVocabulary].
  Future<void> initialize() async {
    _requireActive();
    if (_isInitialized) return;
    if (!repository.isLoaded) {
      throw const QuranTarteelException(QuranTarteelErrorCode.uninitialized);
    }

    await _isolate.start();
    _isolate.updateConfig(_config);
    _isolate.setTajweedMode(_isTajweed);

    _wordSub = _isolate.wordStream.listen(
      _wordEventController.add,
      onError: _wordEventController.addError,
    );
    _reanchorSub = _isolate.autoReanchorStream.listen(
      _autoReanchorController.add,
      onError: _autoReanchorController.addError,
    );
    _trimSub = _isolate.bufferTrimmedStream.listen((event) {
      if (event.segmentEpoch == _currentSegmentId &&
          event.trimmedCharOffset > _confirmedTrimCharOffset) {
        _confirmedTrimCharOffset = event.trimmedCharOffset;
      }
    });

    _isInitialized = true;
  }

  /// Targets [surah] and optionally seeks to [ayah] / 0-based [wordIndex].
  void setTarget({
    required int surah,
    int? ayah,
    int? wordIndex,
  }) {
    _requireActive();
    if (ayah == null && wordIndex == null) {
      setTargetSurah(surah);
    } else if (wordIndex == null) {
      setTargetAyah(surah, ayah!);
    } else {
      setTargetWord(surah: surah, ayah: ayah ?? 1, wordIndex: wordIndex);
    }
  }

  /// Loads 1-based [surahNumber] into the alignment worker starting at [startGlobalWord].
  void setTargetSurah(
    int surahNumber, {
    int startGlobalWord = 0,
  }) {
    _requireActive();
    if (!_isInitialized || !repository.isLoaded) {
      throw const QuranTarteelException(QuranTarteelErrorCode.uninitialized);
    }

    final words = repository.getSurahWords(surahNumber);
    RangeError.checkValueInInterval(
      startGlobalWord,
      0,
      words.length,
      'startGlobalWord',
    );

    _targetSurah = surahNumber;
    _pendingNewSegment = true;
    _currentSegmentId++;
    _confirmedTrimCharOffset = 0;
    _transcriptNormalizer.reset();

    final List<String> phonemeWords = words.map((w) => w.phoneme).toList();
    final List<List<WordTajweedRule>> wordRules =
        words.map((w) => w.rules).toList();
    final List<int> charRuleClasses =
        words.expand((w) => w.charRuleClasses).toList();
    final List<List<String>> wordForms =
        words.map((w) => w.alternateForms).toList();
    final List<int> boundaries = _calculateBoundaries(phonemeWords);
    final String fullPhonemes = phonemeWords.join('');
    final List<int> ayahs = words.map((w) => w.ayah).toList();
    final List<int> wordsInAyah = words.map((w) => w.wordInAyah).toList();

    _isolate.setSurahReference(
      fullPhonemes,
      boundaries,
      isTajweed: _isTajweed,
      startGlobalWord: startGlobalWord,
      surahNumber: surahNumber,
      ayahs: ayahs,
      wordsInAyah: wordsInAyah,
      wordRules: wordRules,
      charRuleClasses: charRuleClasses,
      wordForms: wordForms,
    );
  }

  /// Targets 1-based `(surahNumber, ayahNumber)`.
  void setTargetAyah(int surahNumber, int ayahNumber) {
    _requireActive();
    if (_targetSurah != surahNumber) {
      setTargetSurah(surahNumber);
    }
    final int startWord =
        repository.getAyahStartGlobalIndex(surahNumber, ayahNumber);
    jumpToWord(startWord);
  }

  /// Targets 1-based `(surah, ayah)` at 0-based [wordIndex].
  void setTargetWord({
    required int surah,
    required int ayah,
    required int wordIndex,
  }) {
    _requireActive();
    if (_targetSurah != surah) {
      setTargetSurah(surah);
    }
    final int globalWord =
        repository.getWordGlobalIndex(surah, ayah, wordIndex);
    jumpToWord(globalWord);
  }

  /// Seeks alignment cursor within the active Surah to [globalWordIndex].
  void jumpToWord(int globalWordIndex) {
    _requireActive();
    if (!_isInitialized) {
      throw const QuranTarteelException(QuranTarteelErrorCode.uninitialized);
    }
    _pendingNewSegment = true;
    _currentSegmentId++;
    _confirmedTrimCharOffset = 0;
    _transcriptNormalizer.reset();
    _isolate.jumpToWord(globalWordIndex);
  }

  /// Feeds a cumulative partial or final [TranscriptionResult] into alignment.
  void feedTranscript(TranscriptionResult result) {
    _requireActive();
    if (!_isInitialized) {
      throw const QuranTarteelException(QuranTarteelErrorCode.uninitialized);
    }

    final bool epochChanged = !result.isFinal &&
        _lastStreamEpoch != null &&
        result.streamEpoch != _lastStreamEpoch;
    final bool isNewSegment = _pendingNewSegment || epochChanged;
    if (isNewSegment) {
      _transcriptNormalizer.reset();
      if (epochChanged && !_pendingNewSegment) {
        _currentSegmentId++;
      }
      _confirmedTrimCharOffset = 0;
    }
    if (!result.isFinal) {
      _lastStreamEpoch = result.streamEpoch;
    }

    final normalized = _transcriptNormalizer.normalize(result);
    if (normalized.isEmpty) return;

    final int baseOffset =
        (!isNewSegment && _confirmedTrimCharOffset <= normalized.text.length)
            ? _confirmedTrimCharOffset
            : 0;
    final String sendText = baseOffset > 0
        ? normalized.text.substring(baseOffset)
        : normalized.text;
    final List<double> charTs = normalized.charTimestamps;
    final List<double> sendTs = baseOffset > 0
        ? (baseOffset < charTs.length
            ? charTs.sublist(baseOffset)
            : const <double>[])
        : charTs;
    final List<TokenNeuralAcoustics> charNa = normalized.charNeuralAcoustics;
    final List<TokenNeuralAcoustics> sendNa = baseOffset > 0
        ? (baseOffset < charNa.length
            ? charNa.sublist(baseOffset)
            : const <TokenNeuralAcoustics>[])
        : charNa;

    List<int>? sendTokenIndices;
    List<double>? sendTokenDurations;
    List<double>? sendTokenStarts;
    List<double>? sendTokenEnds;
    if (_isTajweed) {
      final List<int> charTi = normalized.charTokenIndices;
      sendTokenIndices = baseOffset > 0
          ? (baseOffset < charTi.length
              ? charTi.sublist(baseOffset)
              : const <int>[])
          : charTi;
      sendTokenDurations = normalized.durations;
      sendTokenStarts = normalized.starts;
      sendTokenEnds = normalized.ends;
    }

    _pendingNewSegment = false;
    _isolate.syncStream(
      sendText,
      sendTs,
      isNewSegment,
      sendNa,
      sendTokenIndices,
      sendTokenDurations,
      sendTokenStarts,
      sendTokenEnds,
      result.isFinal,
      baseOffset,
      _currentSegmentId,
    );
  }

  /// Starts a new ASR stream segment without losing committed Surah word progress.
  void resetBuffer() {
    _requireActive();
    _pendingNewSegment = true;
    _currentSegmentId++;
    _confirmedTrimCharOffset = 0;
    _transcriptNormalizer.reset();
  }

  /// Toggles Tajweed evaluation mode at runtime.
  void setTajweedMode(bool active) {
    _requireActive();
    _isTajweed = active;
    if (_isInitialized) {
      _isolate.setTajweedMode(active);
    }
  }

  /// Updates alignment, speed, and Tajweed policies at runtime.
  void updateConfig(TrackerConfig newConfig) {
    _requireActive();
    _config = newConfig;
    _transcriptNormalizer.config = newConfig;
    if (_isInitialized) {
      _isolate.updateConfig(newConfig);
    }
  }

  /// Updates active Tajweed rule checks and calibrated thresholds at runtime.
  void updateTajweedConfig(TajweedConfig newTajweedConfig) {
    _requireActive();
    _config = _config.copyWith(tajweed: newTajweedConfig);
    if (_isInitialized) {
      _isolate.updateTajweedConfig(newTajweedConfig);
    }
  }

  List<int> _calculateBoundaries(List<String> phonemeWords) {
    final List<int> boundaries = [0];
    int currentOffset = 0;
    for (final w in phonemeWords) {
      currentOffset += w.length;
      boundaries.add(currentOffset);
    }
    return boundaries;
  }

  /// Terminates the alignment isolate and closes output streams.
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _isInitialized = false;

    _wordSub?.cancel();
    _wordSub = null;
    _reanchorSub?.cancel();
    _reanchorSub = null;
    _trimSub?.cancel();
    _trimSub = null;

    _isolate.stop();

    if (!_wordEventController.isClosed) {
      _wordEventController.close();
    }
    if (!_autoReanchorController.isClosed) {
      _autoReanchorController.close();
    }
  }
}
