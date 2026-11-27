# `quran_tarteel` API & Integration Guide

## 1. Entrypoints

- `package:quran_tarteel/quran_tarteel.dart` — Complete SDK + `TajweedTakeDecoder` + `TajweedSessionBinder` + `AudioProcessor` + `scoring.dart`.
- `package:quran_tarteel/scoring.dart` — Pure-Dart scoring, `QuranRepository`, and `VoiceSearchController` (zero Flutter/recorder imports).

---

## 2. Mode A — Model Output Only (ASR Tokens & Raw Acoustics)

Use `TajweedTakeDecoder` directly when you only want phonetic transcriptions, timestamps, and active head scores (`log_probs`, `attr_qalqalah`, `conf`) without aligning against Quran verses:

```dart
final session = await model.listen(
  options: const TajweedSessionOptions(
    heads: TajweedTakeDecoder.activeHeads,
    topK: TajweedTakeDecoder.defaultTopK,
  ),
);

await for (final result in TajweedTakeDecoder.decodeSessionStream(
  session,
  vocab: model.tokens,
)) {
  // result.text, result.tokens, result.timestamps, result.durations, result.neuralAcoustics
}
```

Or pull final heads via `TajweedTakeDecoder.decodeFinishedHeads(heads)`.

---

## 3. Mode B — Pure-Dart Scoring (`QuranRepository` + `QuranScorer`)

1. Construct and load `QuranRepository` explicitly from `expected_tj3.zfx` bytes:
   - `QuranRepository.fromZfxBytes(bytes, vocabulary: vocab, expectedTokensSha256: ...)`
   - Or using SDK helpers: `repo.loadModelBytes(bytes, model: model)` (verifies `model.calibration?.tokensSha256` automatically).
   - Reloading requires `forceReload: true`; duplicate unforced `loadBytes` calls throw `StateError`.
2. Initialize `QuranScorer`:
   ```dart
   final scorer = QuranScorer(
     repository: repo,
     isTajweed: true,
     config: TrackerConfig(
       recitationSpeed: RecitationSpeed.normal,
       tajweed: TajweedConfig(qalqalahTau: tau),
     ),
   );
   await scorer.initialize();
   scorer.setTargetAyah(1, 1);
   ```
3. Feed cumulative `TranscriptionResult` emissions via `scorer.feedTranscript(result)` and listen to `scorer.onWordEvaluated` (`WordMatchedEvent`) and `scorer.onAutoReanchored` (`AutoReanchorEvent`).
4. Always call `scorer.dispose()` when finished. Calling lifecycle mutators (`setTarget*`, `feedTranscript`, `resetBuffer`, `setTajweedMode`, `updateConfig`, `updateTajweedConfig`) after `dispose()` throws `QuranTarteelException(QuranTarteelErrorCode.disposed)`.

---

## 4. Mode C — Live Session Wiring (`TajweedSessionBinder`)

`TajweedSessionBinder` links any open `TajweedSession` directly to `QuranScorer` without taking ownership of `TajweedClient` or `TajweedModel`:

```dart
final binder = TajweedSessionBinder(
  vocab: model.tokens,
  scorer: scorer,
  onError: (error, stackTrace) {
    // Handle SDK chunk/event stream errors explicitly
  },
);
await binder.attach(session);
// Later on stop:
await binder.finishAndFlush(session);
await binder.dispose();
```

`binder.onTranscription` and `binder.onSessionEvent` also propagate SDK stream errors via Dart's stream `onError` channel.

---

## 5. Voice Search (`VoiceSearchController`)

```dart
final search = VoiceSearchController(repository: repo);
await search.preloadIndex();

// Live partial search while user recites:
await search.processRealtime(result.text);

// Final high-accuracy search on stop:
final VoiceSearchResult? match = await search.stopSearch(result.text);
```

---

## 6. Strict Invariants & Error Semantics

- **Zero silent calibration defaults:** When `TajweedConfig.checkQalqalah` is `true` on a Qalqalah letter, `TajweedConfig.qalqalahTau` must be non-null (typically sourced from `TajweedTakeDecoder.resolveValidatedQalqalahTau(model)`); otherwise `QuranTarteelException(QuranTarteelErrorCode.missingCalibrationThreshold)` is thrown.
- **Zero silent acoustic head fallbacks:** When `requireQalqalahHead` is `true` and `attr_qalqalah` is absent or malformed (`classes < 3` or invalid `frameMs`), `TajweedTakeDecoder` throws `QuranTarteelException(QuranTarteelErrorCode.missingAcousticHead)`.
- **Zero UI or localized strings:** Events expose only structural coordinates (`surah`, `ayah`, `wordInAyah`), numeric scores/durations, and typed enums (`WordEvaluationVerdict`, `ReciterErrorType`, `TajweedDurationStatus`).
