# `quran_tarteel` Documentation

`quran_tarteel` provides direct integration with `quranlab_tajweedformer` (SDK 4.0) alongside a pure-Dart DTW recitation scorer, deterministic Tajweed duration/burst verifier, and Myers bit-parallel Quran voice search index.

---

## Guides

- **[API & Integration Guide](API_GUIDE.md):** Choosing between Model Output Only, `QuranScorer`, and full `TajweedSessionBinder` wiring, plus configuration policies (`TrackerConfig`, `TajweedConfig`, `MatchingPolicy`).

---

## Architecture Overview

```text
  Audio Input (model.listen() / AudioProcessor -> session.push())
                          │
                          ▼
             quranlab_tajweedformer SDK
     (TajweedClient -> TajweedModel -> TajweedSession)
                          │
            ┌─────────────┴─────────────┐
            │ Model-Output Only         │ Full Scoring Pipeline
            ▼                           ▼
   TajweedTakeDecoder          TajweedSessionBinder
   (TranscriptionResult)                │
                                        ▼
                                   QuranScorer
                       ┌────────────────┴────────────────┐
                       ▼                                 ▼
              PhonemeAlignmentIsolate          Deterministic TajweedEngine
         (DTW Word Alignment + Reanchor)    (Blank Attribution + Frontier Shield)
                       │                                 │
                       └────────────────┬────────────────┘
                                        ▼
                        WordMatchedEvent / AutoReanchorEvent
```

## Module Layout (`lib/`)

```text
lib/
├── quran_tarteel.dart   # SDK re-export + AudioProcessor + TajweedTakeDecoder + TajweedSessionBinder + scoring.dart
├── scoring.dart         # Pure-Dart alignment, Tajweed verification, reference & voice search
└── src/
    ├── audio_processor.dart
    ├── config.dart
    ├── core_types.dart
    ├── sdk_bridge.dart
    ├── reference/
    │   ├── quran_repository.dart
    │   └── zfx_loader.dart
    ├── dictation/
    │   ├── auto_reanchor.dart
    │   ├── sequencer.dart
    │   ├── transcript_normalizer.dart
    │   ├── word_matcher.dart
    │   ├── worker.dart
    │   └── worker_transport_{io,web}.dart
    ├── search/
    │   ├── fuzzy_matcher.dart
    │   ├── voice_search.dart
    │   └── search_transport_{io,web}.dart
    └── tajweed/
        ├── tajweed_engine.dart
        └── tajweed_types.dart
```
