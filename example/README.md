<div align="center">

### الحمد لله رب العالمين • بفضل الله و برحمته

</div>

# Example App

This example demonstrates real-time Quran recitation tracking, deterministic Tajweed verification, and voice search using `quran_tarteel` with `quranlab_tajweedformer`.

## Setup

1. Ensure you have your phonetic reference dataset `expected_tj3.zfx` placed in `example/assets/model/expected_tj3.zfx` and listed under `flutter.assets` in `example/pubspec.yaml`.
2. Fetch dependencies and run with your free QuranLab API key (from [sdk.quranlab.ai](https://sdk.quranlab.ai)):

```bash
flutter pub get
flutter run --dart-define=QURANLAB_KEY=qlk_v1_your_api_key_here
```

## What This Demonstrates

1. **Direct SDK Ownership:** `TajweedClient`, `TajweedModel`, and `TajweedSession` owned directly by the app screen and bound to `QuranScorer` via `TajweedSessionBinder`.
2. **Audio Capture:** 16 kHz Float32 microphone streaming via `AudioProcessor`.
3. **Word Evaluation Colors:**
   - **Lead Cursor:** Currently awaited word.
   - **Green:** Recited correctly with valid Tajweed.
   - **Yellow:** Recited correctly with a Tajweed timing/burst warning.
   - **Red:** Mispronounced or skipped word.
4. **Voice Navigation:** Real-time phonetic verse lookup via `VoiceSearchController`.
