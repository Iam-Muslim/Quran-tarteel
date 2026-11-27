<div align="center">

### الحمد لله رب العالمين • بفضل الله و برحمته

</div>

# Changelog

All notable changes to the `quran_tarteel` package are documented in this file.

## 0.2.0 — Matching System Improvements

* **Improved Word Matching & False-Green Rejection**: Refined `QuranDictationMatcher` and `DictationSequencer` alignment calibration, confidence weighting, and boundary handling to prevent false-green commits and cross-word leaks.
* **Streaming Recovery & Frontier Shield**: Improved stutter handling, consecutive-word skip confirmation, lookahead on final Ayah words, and Tajweed Frontier Shield protection for held terminal Madd sounds.
* **Muqattaat & Reference Alignment**: Verified 1:1 Muqattaat alignment with calligraphy word counts in `expected_tj3.zfx` and expanded unit test coverage in `test/word_matcher_test.dart`.

## 0.1.0 — Architecture Modularization & Developer Ergonomics

### Modular Entry Points
* **`package:quran_tarteel/quran_tarteel.dart`**: Unified high-level SDK facade combining on-device neural ASR and full Tajweed verification.
* **`package:quran_tarteel/engine.dart`**: Speech-to-phoneme recognition and acoustics layer. Allows apps to access raw phonemes, timestamps, and neural logits without scoring overhead.
* **`package:quran_tarteel/scoring.dart`**: Pure Dart recitation scoring and Tajweed verification layer. Evaluates transcripts from any speech engine in pure Dart (Flutter, CLI, isolates, servers), with no Flutter asset or ASR dependencies.

### Audio Source Abstraction
* **`QuranAudioSource`**: Pluggable interface for feeding audio into the recognition engine.
* **`MicrophoneAudioSource`**: Native 16 kHz Float32 microphone recording with hardware DSP filters bypassed.
* **`StreamAudioSource`**: Feed external audio streams (WebRTC calls, remote sessions, audio files, synthetic generators).
* **Simplified Audio Lifecycle**: Added `engine.startListening({QuranAudioSource? source})`, `engine.stopListening()`, and `engine.isListening`.

### Pluggable Reference Providers
* **`QuranReferenceProvider`**: Abstract provider decoupling reference metadata (`expected_tj3.zfx`, ayah boundaries, word maps) from Flutter assets.
* **`QuranLabReferenceProvider` (Default in `.sdk()`)**: Dynamically discovers and loads `expected_tj3.zfx` from the on-device cache verified by QuranLab SDK during initialization, without manual asset bundling in `pubspec.yaml`.
* **`FlutterAssetReferenceProvider`**: Asset loader for Flutter applications with cascading fallback paths.
* **`FileReferenceProvider`**: Load reference files directly from the filesystem (desktop, server, or custom cache).
* **`MemoryReferenceProvider`**: In-memory byte array provider for headless unit testing.

### Instant Mus'haf Page Recording
* **Zero-Click Page Start**: Added support for instant re-anchoring when `reanchorStallThreshold == 0` (with a safe query guard of at least 8 phonetic characters), allowing Mus'haf apps to start recording hands-free without requiring the user to tap a verse first.

### Fast Coordinate System
* **32-Bit Packed Key Arithmetic**: Added `packWordKey(surah, ayah, wordIndex)`, `unpackWordKey(key)`, `packAyahKey(surah, ayah)`, and `unpackAyahKey(key)`.
* **Zero Allocation Lookups**: `WordMatchedEvent.packedWordKey`, `WordMatchedEvent.packedAyahKey`, and `AutoReanchorEvent.packedAyahKey` enable instant O(1) integer map lookups in presentation layers without string allocations.

### Structured Lifecycle & Exceptions
* **`QuranTarteelStatus`**: Strongly-typed state machine (`uninitialized`, `downloadingModel`, `ready`, `listening`, `paused`, `error`, `disposed`) exposed via `engine.status` and `engine.onStatusChanged`.
* **Typed Domain Exceptions**: `QuranTarteelException`, `QuranModelDownloadException`, `QuranAuthenticationException`, `QuranAudioSourceException`, `QuranReferenceNotFoundException`, and `QuranTrackingException`.

### Tajweed & Tracking Optimizations
* **Consolidated Tajweed Subsystem**: Merged internal checker classes from `tajweed_checkers.dart` directly into `tajweed_engine.dart`, eliminating circular import cycles and simplifying internal dependencies.
* **Matcher Trace Allocation Bypass**: `QuranDictationMatcher` skips backtrack trace generation when `isTajweed: false`, eliminating unnecessary object allocations during standard recitation.
* **Memoized ASR Tokens**: `AsrTokenProcessor` memoizes character timestamps, neural acoustics, and durations to avoid redundant list allocations during high-frequency audio streaming.

---

## 0.0.1 — Initial Release

* **TajweedFormer V4 Engine**: Integration with the official QuranLab SDK (`quranlab_tajweedformer`).
* **Real-Time Word Recitation Tracking**: Dynamic DTW phoneme alignment across all 6,236 Ayahs.
* **Deterministic Tajweed Matrix**: Real-time verification of Madd durations, Ghunnah, Qalqalah, Shaddah, and Tashkeel.
* **Directional Blank Attribution**: Implementation attributing CTC blanks to true physical phonation intervals.
* **Tajweed Frontier Holding Shield**: Prevents premature word commitments while reciters sustain prolonged vowels into the microphone.
* **Hands-Free Dictation**: Streaming 16 kHz float audio pipeline with automatic verse re-anchoring.
* **Voice Search ("Recite to Navigate")**: Instant sub-second phonetic search across the entire Quran.

---

<div align="center">

### هذا من فضل ربي - ربنا تقبل منا انك انت السميع العليم

</div>
