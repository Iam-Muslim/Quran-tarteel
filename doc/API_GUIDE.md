# API, SDK Wiring & Configuration Guide

## 1. Adding the QuranLab API Key

`quranlab_tajweedformer` requires one process-wide `TajweedClient` initialized with a `qlk_v1_...` key from [sdk.quranlab.ai](https://sdk.quranlab.ai).

Passing the key string to `TajweedClient.create(apiKey)` is the only and most direct activation call supported by the SDK:

```dart
final client = await TajweedClient.create(apiKey);
final model = await client.model();
```

Common ways to supply `apiKey` cleanly:
- **Build-time define (recommended for open repos / CI):**
  ```bash
  flutter run --dart-define=QURANLAB_KEY=qlk_v1_...
  ```
  ```dart
  const key = String.fromEnvironment('QURANLAB_KEY');
  ```
- **Direct constant or backend-fetched string** passed to `TajweedClient.create(key)`.

Notes on SDK behavior:
- `client.model()` downloads/verifies the model bundle (~56 MB) on first launch and caches it locally afterwards.
- Keep `TajweedClient` and `TajweedModel` as app-level singletons (do not re-create per screen or take); only open/close `TajweedSession` per recording take.

---

## 2. Choose Your Integration Mode

### Mode A: Full SDK + Recitation Scoring (`TajweedSessionBinder`)
Use when building from scratch with `quranlab_tajweedformer` + `quran_tarteel.dart`.

```dart
import 'package:flutter/services.dart';
import 'package:quran_tarteel/quran_tarteel.dart';

// 1. Initialize SDK once (e.g. app startup)
final client = await TajweedClient.create(apiKey);
final model = await client.model();

// 2. Load expected_tj3.zfx into QuranRepository
final zfxData = await rootBundle.load('assets/model/expected_tj3.zfx');
final zfxBytes = zfxData.buffer.asUint8List(zfxData.offsetInBytes, zfxData.lengthInBytes);
final repo = QuranRepository()..loadModelBytes(zfxBytes, model: model);

// 3. Configure and start QuranScorer
final qalqalahTau = TajweedTakeDecoder.resolveValidatedQalqalahTau(model);
final scorer = QuranScorer(
  repository: repo,
  isTajweed: true,
  config: TrackerConfig(
    recitationSpeed: RecitationSpeed.normal,
    tajweed: TajweedConfig(qalqalahTau: qalqalahTau),
  ),
);
await scorer.initialize();
scorer.setTargetAyah(112, 1);

// 4. Listen to results
scorer.onWordEvaluated.listen((WordMatchedEvent event) { /* ... */ });
scorer.onAutoReanchored.listen((AutoReanchorEvent event) { /* ... */ });

// 5. Bind sessions per recording take
final binder = TajweedSessionBinder(
  vocab: model.tokens,
  scorer: scorer,
  onError: (error, stackTrace) { /* handle SDK error */ },
);

final session = await model.listen(
  options: const TajweedSessionOptions(
    heads: TajweedTakeDecoder.activeHeads,
    topK: TajweedTakeDecoder.defaultTopK,
  ),
);
await binder.attach(session);

// Stop take:
await binder.finishAndFlush(session);

// Dispose when leaving screen/controller:
await binder.dispose();
scorer.dispose();
```

### Mode B: Existing App Already Configured `quranlab_tajweedformer` (Add Scoring Only)
If your app already creates `TajweedClient`, holds a `TajweedModel`, and starts `TajweedSession`s:

1. Ensure sessions request `TajweedTakeDecoder.activeHeads` (`['log_probs', 'attr_qalqalah', 'conf']`) and `topK: TajweedTakeDecoder.defaultTopK` (`6`) when grading Tajweed (`TajweedTakeDecoder.wordOnlyHeads` = `['log_probs', 'conf']` suffices for plain tracking/search).
2. Load `expected_tj3.zfx` directly against your existing `TajweedModel`:
   ```dart
   final repo = QuranRepository()..loadModelBytes(zfxBytes, model: model);
   ```
   (Or `repo.loadSdkBytes(zfxBytes, tokens: model.tokens, expectedTokensSha256: ...)`.)
3. Create `QuranScorer` + `TajweedSessionBinder` and attach your existing `TajweedSession`:
   ```dart
   final scorer = QuranScorer(
     repository: repo,
     config: TrackerConfig(
       tajweed: TajweedConfig(
         qalqalahTau: TajweedTakeDecoder.resolveValidatedQalqalahTau(model),
       ),
     ),
   );
   await scorer.initialize();
   scorer.setTargetAyah(surah, ayah);

   final binder = TajweedSessionBinder(vocab: model.tokens, scorer: scorer);
   await binder.attach(existingSession);
   ```
`TajweedSessionBinder` never disposes `model` or `client`, and `binder.finishAndFlush(session)` finishes the session cleanly and feeds final heads to `scorer`.

### Mode C: Custom PCM Audio Input (`AudioProcessor` / `Pcm16StreamNormalizer` -> `model.session()`)
Use `model.session()` instead of `model.listen()` when you supply audio yourself (WebRTC remote peer, custom recorder flags with `echoCancel: false` / `autoGain: false` / `noiseSuppress: false`, file chunks):

```dart
final audio = AudioProcessor();
if (!await audio.hasPermission()) return;

final session = await model.session(
  options: const TajweedSessionOptions(
    heads: TajweedTakeDecoder.activeHeads,
    topK: TajweedTakeDecoder.defaultTopK,
  ),
);
await binder.attach(session);

await audio.start(
  onChunk: (Float32List chunk, bool isFinal) {
    session.push(chunk);
  },
);

// Stop:
await audio.stop();
await binder.finishAndFlush(session);
```

If you already receive raw `Uint8List` PCM-16LE packets from another source, use `Pcm16StreamNormalizer` directly:
```dart
final normalizer = Pcm16StreamNormalizer();
// Inside packet callback:
final Float32List? samples = normalizer.push(pcm16LeBytes);
if (samples != null) session.push(samples);
```
`Pcm16StreamNormalizer` safely handles odd-length byte boundaries across packets and scales `int16` to `[-1.0, 1.0]`.

### Mode D: Model Output Only (ASR Tokens & Neural Scores Without Quran Alignment)
Use `TajweedTakeDecoder` directly when you only want phonetic text, token timestamps, `qalqalahScore`, `confScore`, and `altProbs`:

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
- Pass `requireQalqalahHead: false` if your session uses `TajweedTakeDecoder.wordOnlyHeads`.
- On `session.finish()`, call `decoder.decodeFinishedHeads(heads)` to decode the full finalized take.

### Mode E: Pure-Dart Scoring (`package:quran_tarteel/scoring.dart`)
Zero Flutter or `record` imports — usable in server/CLI Dart tools, unit tests, or custom ASR wrappers:

```dart
import 'package:quran_tarteel/scoring.dart';

final repo = QuranRepository.fromZfxBytes(
  zfxBytes,
  vocabulary: PhonemeVocabulary(names: vocabNames, blank: 0, wordBar: 1),
  expectedTokensSha256: expectedSha, // optional strict check
);
final scorer = QuranScorer(
  repository: repo,
  isTajweed: true,
  config: TrackerConfig(tajweed: TajweedConfig(qalqalahTau: 0.50)),
);
await scorer.initialize();
scorer.setTargetSurah(1);
scorer.feedTranscript(transcriptionResult);
```

---

## 3. Navigation & Runtime Control on `QuranScorer`

| Method | Effect |
| :--- | :--- |
| `setTarget({required int surah, int? ayah, int? wordIndex})` | Dispatches to Surah, Ayah, or 0-based word within Ayah. |
| `setTargetSurah(int surah, {int startGlobalWord = 0})` | Loads Surah phonemes and Tajweed rules into the worker and resets the segment cursor. |
| `setTargetAyah(int surah, int ayah)` | Loads Surah if needed and jumps to the first word of 1-based `ayah`. |
| `setTargetWord({required int surah, required int ayah, required int wordIndex})` | Jumps to 0-based `wordIndex` within 1-based `(surah, ayah)`. |
| `jumpToWord(int globalWordIndex)` | Seeks cursor within active Surah (`0 <= index <= surahWords.length`) and clears pending words from `>= index`. |
| `resetBuffer()` | Starts a new ASR transcript buffer segment while keeping committed Surah word progress intact. |
| `setTajweedMode(bool active)` | Toggles Tajweed evaluation at runtime. |
| `updateConfig(TrackerConfig newConfig)` | Updates speed, strictness, policy, reanchor, and Tajweed config at runtime. |
| `updateTajweedConfig(TajweedConfig newTajweedConfig)` | Updates only Tajweed toggles/threshold at runtime. |
| `dispose()` | Stops background worker and closes streams. Subsequent mutators throw `QuranTarteelErrorCode.disposed`. |

`TranscriptionResult` Contract for Custom Producers:
- `feedTranscript(result)` expects **cumulative** partial transcripts per stream epoch (`result.streamEpoch`).
- When switching takes or resetting segments without calling `resetBuffer()`, increment `streamEpoch`; `QuranScorer` auto-resets segment state when `streamEpoch` changes on non-final results.
- `QuranScorer` trims consumed text offsets automatically as `PhonemeAlignmentIsolate` emits `BufferTrimmedEvent` (keeping a 20-char cushion).

---

## 4. Configuration Reference

### `TrackerConfig`
Presets:
- `const TrackerConfig()` / `TrackerConfig.normal()`: `RecitationSpeed.normal`, `MatchingStrictness.normal`, `enableAutoReanchor: false`
- `TrackerConfig.fast()`: `RecitationSpeed.fast`, `MatchingStrictness.easy`, `enableAutoReanchor: true`
- `TrackerConfig.easy()`: `RecitationSpeed.fast`, `MatchingStrictness.easy`, `enableAutoReanchor: false`
- `TrackerConfig.strict()`: `RecitationSpeed.slow`, `MatchingStrictness.hard`, `enableAutoReanchor: false`

Fields:
- `recitationSpeed` (`RecitationSpeed`: `fast`, `normal`, `slow`): Selects harakat duration thresholds in `TajweedEngine`.
- `matchingStrictness` (`MatchingStrictness`: `easy`, `normal`, `hard`): Selects default `MatchingPolicy` when `policy` is `null`.
- `policy` (`MatchingPolicy?`): Explicit DTW & consonant gate overrides.
- `enableAutoReanchor` (`bool`, default `false`): Enables forward recovery when dictation stalls.
- `reanchorStallThreshold` (`int`, default `100`): Minimum unconsumed phonetic chars before auto-reanchor probes.
- `reanchor` (`ReanchorPolicy`): Fine-grained query window and ambiguity thresholds.
- `tajweed` (`TajweedConfig`): Per-rule toggles and `qalqalahTau`.

### `MatchingPolicy` Defaults by `MatchingStrictness`

| Field | `easy` | `normal` (default) | `hard` |
| :--- | :---: | :---: | :---: |
| `defaultMaxPathCost` | `0.38` | `0.30` | `0.22` |
| `shortWordPathCost` (<=2 cons) | `0.35` | `0.26` | `0.20` |
| `mediumWordPathCost` (<=4 cons) | `0.35` | `0.30` | `0.22` |
| `skipMaxPathCost` | `0.30` | `0.25` | `0.18` |
| `maxSkipWords` | `2` | `2` | `1` |
| `acousticConfusionCost` | `0.15` | `0.20` | `0.35` |
| `minAltProbThreshold` | `0.015` | `0.02` | `0.15` |
| `standardInsertionCost` | `0.60` | `0.75` | `1.00` |
| `standardDeletionCost` | `0.80` | `1.00` | `1.00` |
| `maxTokenDurationAllowed` (s) | `3.0` | `2.5` | `2.0` |
| `enforceAcousticOverlapLimit` | `false` | `true` | `true` |
| `minConsonantsForAcousticOverlap` | `2` | `2` | `3` |
| `highConfidenceThreshold` | `0.70` | `0.50` | `0.50` |
| `allowSingleLowConfSlipOnLongWords` | `true` | `true` | `false` |
| `maxLowConfNonAcousticSubs` | `2` | `1` | `1` |
| `allowMissingConsonantOnLongWords` | `true` | `true` | `false` |
| `minMatchedConsonantRatio` | `0.55` | `0.65` | `0.65` |

Structural word-gate invariants enforced by `QuranDictationMatcher`:
- Terminal deleted Madd (2+ deleted Madd chars at word end) fails matching so held endings aren't prematurely committed.
- Deleting the last consonant always fails matching; deleting the first consonant when `matchStart > 0` fails matching.
- High-confidence non-acoustic consonant substitutions (`confScore >= highConfidenceThreshold` and `altProb < minAltProbThreshold`) always fail matching.
- Words with multiple acceptable Tajweed/Waqf/Wasl pronunciations (`surahWordForms` from `expected_tj3.zfx`) are evaluated against canonical + alternate forms via `VariantWordMatcher`.

---

## 5. Error Semantics (`QuranTarteelException`)

Every failure condition raises a typed `QuranTarteelException(code, [cause])`:

| `QuranTarteelErrorCode` | When Thrown |
| :--- | :--- |
| `uninitialized` | `initialize()` / `setTarget*` / `feedTranscript` / `VoiceSearchController` before repository or scorer is initialized. |
| `disposed` | Using `QuranScorer` or `TajweedSessionBinder` after `dispose()`. |
| `invalidReferenceData` | Malformed `expected_tj3.zfx` (`ZFTJEXP1` header/size/version), empty vocabulary, or `tokensSha256` mismatch. |
| `missingCalibrationThreshold` | `TajweedConfig.checkQalqalah` triggers on a Qalqalah letter while `qalqalahTau == null`, `requireValidatedQalqalahTau(model)` finds no `'validated'` threshold, or `loadModelBytes(..., verifyTokensSha256: true)` sees missing `model.calibration?.tokensSha256`. |
| `missingAcousticHead` | `log_probs` is missing, or `requireQalqalahHead: true` and `attr_qalqalah` is missing / `classes < 3` / invalid `frameMs`. |
| `isolateStartTimeout` | Background alignment isolate did not complete startup handshake within 10 seconds. |

Repository loading guard: calling `repo.loadBytes(...)` / `loadSdkBytes(...)` / `loadModelBytes(...)` twice throws `StateError` unless `forceReload: true`.
