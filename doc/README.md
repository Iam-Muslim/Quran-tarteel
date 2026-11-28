# `quran_tarteel` Documentation

`quran_tarteel` wraps pure-Dart Quran alignment, deterministic Tajweed verification, and phonetic search around the official `quranlab_tajweedformer` SDK (`4.0.4`).

## Guides

| Guide | Covers |
| :--- | :--- |
| **[API, SDK Wiring & Configuration](API_GUIDE.md)** | API key activation, all wiring modes (full SDK, existing-SDK scoring-only, custom PCM `AudioProcessor`, pure-Dart `scoring.dart`, model-output-only), `TrackerConfig`, `MatchingPolicy`, lifecycle, and exceptions. |
| **[Voice Search & Auto-Reanchor](VOICE_SEARCH_AND_REANCHOR.md)** | `VoiceSearchController`, `PhoneticSearch`, prefix ignoring, adaptive ratios, uniqueness detection, and `AutoReanchorFinder` forward stall recovery. |
| **[Tajweed Rules & Grading](TAJWEED_RULES_AND_GRADING.md)** | `expected_tj3.zfx` rule taxonomy (`1..11`), `TajweedConfig`, `RecitationSpeed` duration tables, `SpanDurationCalculator`, `HeldFrontierShield`, Qalqalah burst scoring, and `WordMatchedEvent` / `ReciterError`. |

## Data Flow

```text
  Microphone / PCM Stream
    ├─ SDK mic: model.listen(...)
    └─ Custom PCM: AudioProcessor / Pcm16StreamNormalizer ──► session.push(Float32List)
                           │
                           ▼
              quranlab_tajweedformer SDK
     (TajweedClient ──► TajweedModel ──► TajweedSession)
                           │
           ┌───────────────┴───────────────┐
           │ Voice Search / ASR Only       │ Full Recitation Scoring
           ▼                               ▼
  TajweedTakeDecoder              TajweedSessionBinder
   (TranscriptionResult)                   │
           │                               ▼
           ▼                          QuranScorer
  VoiceSearchController        (TranscriptNormalizer)
  (PhoneticSearch Isolate)                 │
   ──► VoiceSearchResult                   ▼
                                PhonemeAlignmentIsolate
                             ┌─────────────┴─────────────┐
                             ▼                           ▼
                    DictationSequencer            TajweedEngine
               (DTW + HeldFrontierShield     (Blank Attribution +
                + AutoReanchorFinder)          Qalqalah / Duration)
                             │                           │
                             └─────────────┬─────────────┘
                                           ▼
                          WordMatchedEvent / AutoReanchorEvent
```

## Module Layout (`lib/`)

```text
lib/
├── quran_tarteel.dart              # Main entrypoint: re-exports quranlab_tajweedformer + scoring.dart + AudioProcessor + TajweedTakeDecoder + TajweedSessionBinder
├── scoring.dart                    # Pure-Dart entrypoint: QuranScorer + exported config/core/reference/search/tajweed types
└── src/
    ├── audio_processor.dart        # 16 kHz mono PCM-16LE -> Float32 mic recorder & Pcm16StreamNormalizer
    ├── config.dart                 # RecitationSpeed, TajweedConfig, MatchingStrictness, MatchingPolicy, ReanchorPolicy, TrackerConfig
    ├── core_types.dart             # QuranTarteelException, QuranCoordinate, PhoneticSymbols, TranscriptionResult, PhonemeVocabulary
    ├── sdk_bridge.dart             # vocabularyFromSdk, QuranRepositorySdkExtension, TajweedTakeDecoder
    ├── reference/
    │   ├── quran_repository.dart   # In-memory Surah/Ayah phoneme & rule cache
    │   └── zfx_loader.dart         # 'ZFTJEXP1' binary parser, MaddEntry, WordTajweedRule, ComposedWord, QuranVerse
    ├── dictation/
    │   ├── auto_reanchor.dart      # AutoReanchorFinder (forward fuzzy scan + Mutashabihat ambiguity guard)
    │   ├── sequencer.dart          # DictationSequencer (sliding window, skip-word verification, frontier shield calls, commits)
    │   ├── transcript_normalizer.dart # Filters <blk>/|, computes token starts/ends, expands char alignment arrays
    │   ├── word_matcher.dart       # DTW QuranDictationMatcher, PhoneticCostEngine, structural gates, VariantWordMatcher
    │   ├── worker.dart             # WordMatchedEvent, AutoReanchorEvent, PhonemeAlignmentIsolate
    │   └── worker_transport_{io,web}.dart
    ├── search/
    │   ├── fuzzy_matcher.dart      # 64-bit Myers bit-parallel + DP fallback near-matcher
    │   ├── search_transport_{io,web}.dart
    │   └── voice_search.dart       # PhoneticSearch index + VoiceSearchController
    └── tajweed/
        ├── tajweed_engine.dart     # SpanDurationCalculator, HeldFrontierShield, TajweedEngine
        └── tajweed_types.dart      # TajweedRuleType (1..11), AcousticThreshold tables, TajweedRule hierarchy, ReciterError
```
