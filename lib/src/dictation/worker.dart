// lib/src/dictation/worker.dart
import 'dart:async';

import '../config.dart';
import '../core_types.dart';
import '../reference/zfx_loader.dart';
import '../tajweed/tajweed_types.dart';
import 'worker_transport_io.dart'
    if (dart.library.js_interop) 'worker_transport_web.dart';

enum WordEvaluationVerdict {
  correct,
  tajweedWarning,
  skipped,
}

sealed class IsolateCommand {
  const IsolateCommand();
}

class SetSurahReferenceCommand extends IsolateCommand {
  final String fullPhonemes;
  final List<int> boundaries;
  final int surahNumber;
  final List<int> ayahs;
  final List<int> wordsInAyah;
  final bool isTajweed;
  final int startGlobalWord;
  final List<List<WordTajweedRule>>? wordRules;
  final List<int>? charRuleClasses;
  final List<List<String>>? wordForms;

  const SetSurahReferenceCommand({
    required this.fullPhonemes,
    required this.boundaries,
    required this.surahNumber,
    this.ayahs = const [],
    this.wordsInAyah = const [],
    this.isTajweed = false,
    this.startGlobalWord = 0,
    this.wordRules,
    this.charRuleClasses,
    this.wordForms,
  });
}

class SyncStreamCommand extends IsolateCommand {
  final String asrText;
  final int baseCharOffset;
  final int segmentId;
  final List<double> timestamps;
  final bool isNewSegment;
  final bool isFinal;
  final List<TokenNeuralAcoustics> neuralAcoustics;
  final List<int>? charTokenIndices;
  final List<double>? tokenDurations;
  final List<double>? tokenStarts;
  final List<double>? tokenEnds;

  const SyncStreamCommand({
    required this.asrText,
    this.baseCharOffset = 0,
    this.segmentId = 0,
    required this.timestamps,
    this.isNewSegment = false,
    this.isFinal = false,
    this.neuralAcoustics = const [],
    this.charTokenIndices,
    this.tokenDurations,
    this.tokenStarts,
    this.tokenEnds,
  });
}

class JumpToWordCommand extends IsolateCommand {
  final int globalWordIndex;
  const JumpToWordCommand({required this.globalWordIndex});
}

class SetTajweedModeCommand extends IsolateCommand {
  final bool isTajweed;
  const SetTajweedModeCommand({required this.isTajweed});
}

class UpdateTrackerConfigCommand extends IsolateCommand {
  final TrackerConfig config;
  const UpdateTrackerConfigCommand({required this.config});
}

class UpdateTajweedConfigCommand extends IsolateCommand {
  final TajweedConfig tajweed;
  const UpdateTajweedConfigCommand({required this.tajweed});
}

class StopIsolateCommand extends IsolateCommand {
  const StopIsolateCommand();
}

sealed class IsolateEvent {
  const IsolateEvent();
}

class WordMatchedEvent extends IsolateEvent {
  final int wordId;
  final int surah;
  final int ayah;
  final int wordInAyah;
  final WordEvaluationVerdict verdict;
  final double score;
  final String cleanAsr;
  final String expectedPhonemes;
  final List<ReciterError>? tajweedErrors;
  final double startTimestamp;
  final double endTimestamp;

  const WordMatchedEvent({
    required this.wordId,
    this.surah = 0,
    this.ayah = 0,
    this.wordInAyah = 0,
    this.verdict = WordEvaluationVerdict.correct,
    this.score = 0.0,
    required this.cleanAsr,
    this.expectedPhonemes = '',
    this.tajweedErrors,
    this.startTimestamp = 0.0,
    this.endTimestamp = 0.0,
  });

  bool get isRight =>
      verdict == WordEvaluationVerdict.correct ||
      verdict == WordEvaluationVerdict.tajweedWarning;
  int get packedWordKey => QuranCoordinate.packWordKey(surah, ayah, wordInAyah);
  int get wordIndex => wordInAyah;
}

class AutoReanchorEvent extends IsolateEvent {
  final int previousWordIndex;
  final int newWordIndex;
  final int surah;
  final int ayah;
  final int wordInAyah;
  final int editDistance;
  final int probeOffset;

  const AutoReanchorEvent({
    required this.previousWordIndex,
    required this.newWordIndex,
    required this.surah,
    required this.ayah,
    required this.wordInAyah,
    required this.editDistance,
    required this.probeOffset,
  });

  int get packedWordKey => QuranCoordinate.packWordKey(surah, ayah, wordInAyah);
  int get packedAyahKey => QuranCoordinate.packAyahKey(surah, ayah);
}

class BufferTrimmedEvent extends IsolateEvent {
  final int segmentEpoch;
  final int trimmedCharOffset;

  const BufferTrimmedEvent({
    required this.segmentEpoch,
    required this.trimmedCharOffset,
  });
}

class IsolateErrorEvent extends IsolateEvent {
  final Object error;
  final StackTrace? stackTrace;

  const IsolateErrorEvent(this.error, [this.stackTrace]);
}

class PhonemeAlignmentIsolate {
  late final AlignmentWorkerTransport _transport =
      AlignmentWorkerTransport(onEvent: _routeEvent);

  final StreamController<WordMatchedEvent> _wordStreamController =
      StreamController<WordMatchedEvent>.broadcast();
  final StreamController<AutoReanchorEvent> _autoReanchorStreamController =
      StreamController<AutoReanchorEvent>.broadcast();
  final StreamController<BufferTrimmedEvent> _bufferTrimmedStreamController =
      StreamController<BufferTrimmedEvent>.broadcast();

  Stream<WordMatchedEvent> get wordStream => _wordStreamController.stream;
  Stream<AutoReanchorEvent> get autoReanchorStream =>
      _autoReanchorStreamController.stream;
  Stream<BufferTrimmedEvent> get bufferTrimmedStream =>
      _bufferTrimmedStreamController.stream;

  Future<void> start() => _transport.start();

  void _routeEvent(IsolateEvent event) {
    switch (event) {
      case WordMatchedEvent():
        _wordStreamController.add(event);
      case AutoReanchorEvent():
        _autoReanchorStreamController.add(event);
      case BufferTrimmedEvent():
        _bufferTrimmedStreamController.add(event);
      case IsolateErrorEvent(:final error, :final stackTrace):
        _wordStreamController.addError(error, stackTrace);
    }
  }

  void send(IsolateCommand command) => _transport.send(command);

  void setSurahReference(
    String expectedPhonemes,
    List<int> wordBoundaries, {
    bool isTajweed = false,
    int startGlobalWord = 0,
    int surahNumber = 0,
    List<int> ayahs = const [],
    List<int> wordsInAyah = const [],
    List<List<WordTajweedRule>>? wordRules,
    List<int>? charRuleClasses,
    List<List<String>>? wordForms,
  }) {
    send(
      SetSurahReferenceCommand(
        fullPhonemes: expectedPhonemes,
        boundaries: wordBoundaries,
        surahNumber: surahNumber,
        ayahs: ayahs,
        wordsInAyah: wordsInAyah,
        isTajweed: isTajweed,
        startGlobalWord: startGlobalWord,
        wordRules: wordRules,
        charRuleClasses: charRuleClasses,
        wordForms: wordForms,
      ),
    );
  }

  void jumpToWord(int globalWordIndex) {
    send(JumpToWordCommand(globalWordIndex: globalWordIndex));
  }

  void syncStream(
    String segmentText,
    List<double>? segmentTimestamps, [
    bool isNewSegment = false,
    List<TokenNeuralAcoustics>? neuralAcoustics,
    List<int>? charTokenIndices,
    List<double>? tokenDurations,
    List<double>? tokenStarts,
    List<double>? tokenEnds,
    bool isFinal = false,
    int baseCharOffset = 0,
    int segmentId = 0,
  ]) {
    send(
      SyncStreamCommand(
        asrText: segmentText,
        baseCharOffset: baseCharOffset,
        segmentId: segmentId,
        timestamps: segmentTimestamps ?? const [],
        isNewSegment: isNewSegment,
        isFinal: isFinal,
        neuralAcoustics: neuralAcoustics ?? const [],
        charTokenIndices: charTokenIndices,
        tokenDurations: tokenDurations,
        tokenStarts: tokenStarts,
        tokenEnds: tokenEnds,
      ),
    );
  }

  void setTajweedMode(bool isTajweed) {
    send(SetTajweedModeCommand(isTajweed: isTajweed));
  }

  void updateConfig(TrackerConfig config) {
    send(UpdateTrackerConfigCommand(config: config));
  }

  void updateTajweedConfig(TajweedConfig tajweedConfig) {
    send(UpdateTajweedConfigCommand(tajweed: tajweedConfig));
  }

  void stop() {
    _transport.stop();
    _wordStreamController.close();
    _autoReanchorStreamController.close();
    _bufferTrimmedStreamController.close();
  }
}
