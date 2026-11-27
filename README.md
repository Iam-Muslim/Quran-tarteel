<div align="center">

# وما اسالكم عليه من اجر ان اجري الا على رب العالمين
### الحمد لله رب العالمين • بفضل الله و برحمته

# Quran Tarteel — ترتيل القرآن
**Real-time on-device Quran recitation tracking, dynamic word alignment, and deterministic Tajweed verification for Flutter & Dart powered by TajweedFormer V4**

*Dedicated for the sake of Allah (لوجه الله تعالى) — free and non-commercial.*

*[QuranLab](https://quranlab.ai)'s [TajweedFormer V4](https://huggingface.co/Quran-Lab/tajweedformer-v4) model.*

</div>

---

## Overview

`quran_tarteel` is a headless, zero-UI, zero-strings Quran recitation tracking, Tajweed grading, and phonetic search engine built directly on top of the official `quranlab_tajweedformer` SDK 4.0:
* **Direct SDK Communication:** Your app owns `TajweedClient`, `TajweedModel`, and `TajweedSession` directly from `quranlab_tajweedformer` with zero hidden wrappers, zero guessed defaults, and zero swallowed SDK errors.
* **Two Clean Public Entrypoints:**
  1. **Model Output Only (`TajweedTakeDecoder` via `quran_tarteel.dart`):** Feed `TajweedSession.chunks` directly to obtain phonetic tokens, frame timestamps, `qalqalahScore`, and `altProbs` without loading any Quran reference or alignment engine.
  2. **Pure-Dart Scoring Only (`package:quran_tarteel/scoring.dart`):** Pass `expected_tj3.zfx` bytes + `PhonemeVocabulary` + `TranscriptionResult` into `QuranScorer` with zero Flutter/recorder dependencies.
  3. **Full SDK + Audio + Scoring (`package:quran_tarteel/quran_tarteel.dart`):** Combines `quranlab_tajweedformer`, optional 16 kHz PCM capture (`AudioProcessor` / `Pcm16StreamNormalizer`), `TajweedTakeDecoder`, `TajweedSessionBinder`, and `scoring.dart`.
* **Deterministic Tajweed Grading:** Bidirectional CTC blank attribution (`SpanDurationCalculator`) for Madd, Ghunnah, and Shaddah, Qalqalah burst scoring via `attr_qalqalah`, and streaming frontier holding (`HeldFrontierShield`).
* **6,236-Ayah Phonetic Voice Search:** Myers 64-bit bit-parallel search in a background isolate (`VoiceSearchController`).

---

## Package Entry Points

```text
package:quran_tarteel/
├── quran_tarteel.dart   # Re-exports quranlab_tajweedformer + scoring.dart + AudioProcessor + TajweedTakeDecoder + TajweedSessionBinder
└── scoring.dart         # Pure-Dart QuranRepository, QuranScorer, VoiceSearchController, TajweedConfig, TrackerConfig
```

---

## Usage Examples

### 1. Model Output Only (No Quran Reference / Matching)
```dart
import 'package:quran_tarteel/quran_tarteel.dart';

final client = await TajweedClient.create('qlk_v1_YOUR_KEY');
final model = await client.model();
final session = await model.listen(
  options: const TajweedSessionOptions(
    heads: TajweedTakeDecoder.activeHeads,
    topK: TajweedTakeDecoder.defaultTopK,
  ),
);

final decoder = TajweedTakeDecoder(vocab: model.tokens);
session.chunks.listen((chunk) {
  final result = decoder.decodeChunk(chunk);
  // result.text, result.tokens, result.timestamps, result.durations, result.neuralAcoustics
});
```

### 2. Full Recitation Tracking & Tajweed Scoring
```dart
import 'package:flutter/services.dart';
import 'package:quran_tarteel/quran_tarteel.dart';

final client = await TajweedClient.create('qlk_v1_YOUR_KEY');
final model = await client.model();

// Load expected_tj3.zfx explicitly and verify model.calibration?.tokensSha256
final zfxData = await rootBundle.load('assets/model/expected_tj3.zfx');
final zfxBytes = zfxData.buffer.asUint8List(zfxData.offsetInBytes, zfxData.lengthInBytes);

final repo = QuranRepository();
repo.loadModelBytes(zfxBytes, model: model);

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
  // Coordinates + typed verdict & ReciterError list (zero UI/strings)
});

final binder = TajweedSessionBinder(
  vocab: model.tokens,
  scorer: scorer,
  onError: (err, st) => debugPrint('SDK stream error: $err'),
);
final session = await model.listen(
  options: const TajweedSessionOptions(
    heads: TajweedTakeDecoder.activeHeads,
    topK: TajweedTakeDecoder.defaultTopK,
  ),
);
await binder.attach(session);
```

### 3. Pure-Dart Scoring Only (`package:quran_tarteel/scoring.dart`)
```dart
import 'package:quran_tarteel/scoring.dart';

final repo = QuranRepository.fromZfxBytes(
  zfxBytes,
  vocabulary: PhonemeVocabulary(
    names: vocabNames,
    blank: 0,
    wordBar: 1,
  ),
);
final scorer = QuranScorer(
  repository: repo,
  config: TrackerConfig(tajweed: TajweedConfig(qalqalahTau: 0.5)),
);
await scorer.initialize();
scorer.setTargetSurah(1);
scorer.feedTranscript(transcriptionResult);
```

See [doc/README.md](doc/README.md) and [doc/API_GUIDE.md](doc/API_GUIDE.md) for architecture details and configuration.

---

## Requirements for Consuming Apps
1. **QuranLab API Key** (`qlk_v1_...` from [sdk.quranlab.ai](https://sdk.quranlab.ai)) passed directly to `TajweedClient.create(apiKey)`.
2. **Platform configuration** for `quranlab_tajweedformer` (Android `minSdk >= 26`, iOS `NSMicrophoneUsageDescription` + simulator `EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64`).
3. **`expected_tj3.zfx` bytes** when using `QuranRepository` / `QuranScorer` / `VoiceSearchController`.
4. **Optional raw PCM capture (`AudioProcessor`)** only when pushing custom audio into `model.session()` (e.g., WebRTC); standard microphone apps can use `model.listen()` natively.

---

## License (لوجه الله تعالى)

This package and its source code are dedicated for the sake of Allah alone:
1. **Free to End Users:** You may use, distribute, or modify this software only in apps and services that are completely free of charge to all users.
2. **Strictly Non-Commercial:** You may not sell this software, put it behind subscriptions, paywalls, or in-app purchases, charge download fees, or monetize it with advertising.
3. **Pass-Through:** Any forks or derivative works must remain open and inherit these exact terms.
