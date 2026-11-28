<div align="center">

# وما اسالكم عليه من اجر ان اجري الا على رب العالمين
### الحمد لله رب العالمين • بفضل الله و برحمته

# Quran Tarteel — ترتيل القرآن
**On-device Quran recitation tracking, dynamic DTW word alignment, deterministic Tajweed grading, and phonetic voice search for Flutter & Dart powered by TajweedFormer V4.**

*Dedicated for the sake of Allah (لوجه الله تعالى) — free and non-commercial.*

*Built on [QuranLab](https://quranlab.ai)'s [TajweedFormer V4](https://huggingface.co/Quran-Lab/tajweedformer-v4) (`quranlab_tajweedformer`).*

</div>

---

## What It Does

- **Recitation Tracking (`QuranScorer`):** Aligns streaming ASR phoneme emissions against `expected_tj3.zfx` in a background worker (`Isolate` on IO, async stream on Web), supporting within-surah word/ayah targeting (`setTarget`, `setTargetSurah`, `setTargetAyah`, `setTargetWord`, `jumpToWord`), pronunciation variants, and word skipping up to `maxSkipWords`.
- **Deterministic Tajweed Grading (`TajweedEngine`):** Evaluates Madd (`1..7`), Qalqalah (`8`), Shaddah (`9`), Ghunnah (`10`), letter substitutions/deletions, and harakat (`checkTashkeel`) using active SDK heads (`log_probs`, `attr_qalqalah`, `conf`), bidirectional CTC blank attribution (`SpanDurationCalculator`), and streaming commit protection (`HeldFrontierShield`).
- **Auto-Reanchor (`AutoReanchorFinder`):** When enabled (`TrackerConfig.enableAutoReanchor`), recovers lost position by scanning strictly forward in the active Surah once unconsumed ASR buffer hits `reanchorStallThreshold`, with Mutashabihat ambiguity rejection.
- **Voice Search (`VoiceSearchController`):** Searches all 6,236 ayahs in a background isolate using 64-bit Myers bit-parallel fuzzy matching with optional prefix stripping (`A'udhu` / `Basmala`), adaptive error ratio, and uniqueness scoring.
- **Zero UI / Zero Swallowed Errors:** Emits typed structural events (`WordMatchedEvent`, `AutoReanchorEvent`, `VoiceSearchResult`) and propagates SDK/validation errors explicitly via `QuranTarteelException`.

---

## Package Entry Points

```text
package:quran_tarteel/
├── quran_tarteel.dart   # Re-exports quranlab_tajweedformer + scoring.dart + AudioProcessor + Pcm16StreamNormalizer + TajweedTakeDecoder + TajweedSessionBinder
└── scoring.dart         # Pure-Dart QuranRepository, QuranScorer, VoiceSearchController, config, and Tajweed types (no Flutter/record deps)
```

---

## Quick Start

### 1. API Key Activation (`quranlab_tajweedformer`)
Get an API key (`qlk_v1_...`) from [sdk.quranlab.ai](https://sdk.quranlab.ai). Initialize `TajweedClient` once per process and fetch `TajweedModel`:

```dart
import 'package:quran_tarteel/quran_tarteel.dart';

// Direct key or injected via --dart-define=QURANLAB_KEY=qlk_v1_...
const apiKey = String.fromEnvironment('QURANLAB_KEY', defaultValue: 'qlk_v1_YOUR_KEY');
final client = await TajweedClient.create(apiKey);
final model = await client.model();
```

### 2. Full Microphone Recitation Tracking (`model.listen()` + `TajweedSessionBinder`)
```dart
import 'package:flutter/services.dart';
import 'package:quran_tarteel/quran_tarteel.dart';

final zfxData = await rootBundle.load('assets/model/expected_tj3.zfx');
final zfxBytes = zfxData.buffer.asUint8List(zfxData.offsetInBytes, zfxData.lengthInBytes);

final repo = QuranRepository()..loadModelBytes(zfxBytes, model: model);

final qalqalahTau = TajweedTakeDecoder.resolveValidatedQalqalahTau(model);
final scorer = QuranScorer(
  repository: repo,
  isTajweed: true,
  config: TrackerConfig(
    tajweed: TajweedConfig(qalqalahTau: qalqalahTau),
  ),
);
await scorer.initialize();
scorer.setTargetAyah(1, 1);

scorer.onWordEvaluated.listen((WordMatchedEvent event) {
  // event.surah, event.ayah, event.wordInAyah, event.verdict, event.tajweedErrors
});

final binder = TajweedSessionBinder(
  vocab: model.tokens,
  scorer: scorer,
  onError: (err, st) => debugPrint('SDK error: $err'),
);

final session = await model.listen(
  options: const TajweedSessionOptions(
    heads: TajweedTakeDecoder.activeHeads,
    topK: TajweedTakeDecoder.defaultTopK,
  ),
);
await binder.attach(session);

// On stop:
await binder.finishAndFlush(session);
```

### 3. Adding Scoring to an App That Already Owns `TajweedClient` / `TajweedModel`
Import `quran_tarteel.dart` alongside your existing `quranlab_tajweedformer` setup. Use `repo.loadModelBytes(zfxBytes, model: model)` and bind any open `TajweedSession` with `TajweedSessionBinder(vocab: model.tokens, scorer: scorer)` — `quran_tarteel` never takes ownership of `client`, `model`, or `session`. See [doc/API_GUIDE.md](doc/API_GUIDE.md) for details.

### 4. Voice Search (`VoiceSearchController`)
```dart
final search = VoiceSearchController(
  repository: repo,
  useAdaptiveErrorRatio: true,
  allowSuffixFallback: true,
);
await search.preloadIndex();

final session = await model.listen(
  options: const TajweedSessionOptions(heads: TajweedTakeDecoder.wordOnlyHeads),
);
session.chunks.listen((chunk) {
  final text = TajweedTakeDecoder.formatDecodedText(chunk.decoded.tokens);
  if (text.isNotEmpty) search.processRealtime(text);
});

search.onSearchResult.listen((VoiceSearchResult? result) {
  final top = result?.topMatch; // surah, ayah, wordIdx, score, isUnique
});
```

---

## Documentation

- **[Documentation Index & Architecture](doc/README.md)**
- **[API, SDK Wiring & Configuration](doc/API_GUIDE.md)** — API key setup, 4 integration modes, custom PCM streaming (`AudioProcessor`), `TrackerConfig` / `MatchingPolicy`, and error codes.
- **[Voice Search & Auto-Reanchor](doc/VOICE_SEARCH_AND_REANCHOR.md)** — Fuzzy index, `VoiceSearchController` API, uniqueness scoring, and forward stall recovery.
- **[Tajweed Rules & Grading](doc/TAJWEED_RULES_AND_GRADING.md)** — `expected_tj3.zfx` rule IDs (`1..11`), thresholds per `RecitationSpeed`, bidirectional blank attribution, Qalqalah burst scoring, `HeldFrontierShield`, and `ReciterError` interpretation.

---

## Requirements

1. **QuranLab API Key** (`qlk_v1_...` from [sdk.quranlab.ai](https://sdk.quranlab.ai)).
2. **Platform configuration** for `quranlab_tajweedformer`:
   - Android: `minSdk >= 26`
   - iOS: iOS 15+, `NSMicrophoneUsageDescription` in `Info.plist`, and simulator `EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64`
3. **`expected_tj3.zfx` asset** for `QuranRepository`, `QuranScorer`, and `VoiceSearchController`.
4. **Raw PCM helper (`AudioProcessor`):** Optional; only needed if you push your own 16 kHz audio stream into `model.session()`. Standard mic capture can use `model.listen()`.

---

## License (لوجه الله تعالى)

Dedicated for the sake of Allah alone:
1. **Free to End Users:** May be used, distributed, or modified only in apps and services completely free of charge to all users.
2. **Strictly Non-Commercial:** May not be sold, placed behind paywalls/subscriptions/IAPs, or monetized with ads.
3. **Pass-Through:** Forks and derivative works must remain open under these exact terms.
