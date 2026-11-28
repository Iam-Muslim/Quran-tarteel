# Tajweed Rules, Acoustic Timing & Grading Guide

## 1. Rule Taxonomy (`expected_tj3.zfx` Single Source of Truth)

Tajweed sites are read exclusively from `expected_tj3.zfx` (`WordTajweedRule` and per-character `charRuleClasses` in `QuranVerse` / `ContinuousQuranWord`). Nothing is hardcoded by phoneme letter in Dart.

| `ruleId` | `TajweedRuleType` | Model / Description | Canonical `goldenLen` |
| :---: | :--- | :--- | :---: |
| `1` | `maddNormal` | Madd Tabee'i (`MaddRule`) | `2` harakat |
| `2` | `maddMonfasel` | Madd Ja'iz Monfasel (`MaddRule`) | `2 / 4 / 5` (by speed) |
| `3` | `maddMottasel` | Madd Wajib Mottasel (`MaddRule`) | `4 / 4 / 5` (by speed) |
| `4` | `maddMottaselPause` | Madd Wajib Mottasel on Waqf (`MaddRule`) | `4 / 4 / 6` (by speed) |
| `5` | `maddAared` | Madd 'Arid lis-Sukoon (`MaddRule`) | `2 / 4 / 6` (by speed) |
| `6` | `maddLazem` | Madd Lazem (`MaddRule`) | `6` harakat |
| `7` | `maddLeen` | Madd Leen (`MaddRule`) | `2 / 4 / 6` (by speed) |
| `8` | `qalqalah` | Qalqalah burst (`QalqalahRule`: `level` `1` sughra, `2` kubra) | `1` |
| `9` | `shaddah` | Gemination (`ShaddahRule`) | `1.5` |
| `10` | `ghunnah` | Nasalization (`MushaddadGhunnahRule`: `ghunnaExpected` `2` mushaddad, `3` ikhfaa/iqlab, `4` idgham) | `2` |
| `11` | `plainLetter` | Plain non-tajweed consonant span (`PlainLetterRule`) | `0` |
| `0` | `other` | Fallback / unmapped ID | — |

Note on Qalqalah suppression at Wasl: if `buildWordSpans` sees a `qalqalah` span immediately followed within the same word by a phonetic vowel (`PhoneticSymbols.isVowelChar`), Qalqalah is marked inactive (`isQalqalah: false`) because the consonant is vocalized, not sakin.

---

## 2. Calibrated Acoustic Thresholds (`TajweedDurationStatus`)

Each `TajweedRule` evaluates measured duration in seconds against `AcousticThreshold(minSeconds, targetSeconds, maxSeconds)` selected by `TrackerConfig.recitationSpeed`:

| Rule | `fast` (`min` / `target` / `max` s) | `normal` (`min` / `target` / `max` s) | `slow` (`min` / `target` / `max` s) |
| :--- | :--- | :--- | :--- |
| `maddNormal` (1) | `0.075 / 0.240 / 0.600` | `0.150 / 0.300 / 0.700` | `0.180 / 0.360 / 0.850` |
| `maddMonfasel` (2) | `0.180 / 0.240 / 0.800` | `0.450 / 0.600 / 1.400` | `0.650 / 0.900 / 1.800` |
| `maddMottasel` (3) | `0.350 / 0.480 / 1.200` | `0.450 / 0.600 / 1.500` | `0.650 / 0.900 / 1.800` |
| `maddMottaselPause` (4) | `0.350 / 0.480 / 1.800` | `0.450 / 0.600 / 2.000` | `0.800 / 1.080 / 2.500` |
| `maddAared` (5), `maddLeen` (7) | `0.120 / 0.240 / 1.800` | `0.300 / 0.600 / 2.200` | `0.500 / 1.080 / 2.500` |
| `maddLazem` (6) | `0.540 / 0.720 / 4.000` | `0.680 / 0.900 / 4.000` | `0.850 / 1.080 / 4.500` |
| `ghunnah` (10) | `0.180 / 0.240 / 0.850` | `0.225 / 0.300 / 0.850` | `0.270 / 0.360 / 1.600` |
| `shaddah` (9) | `0.140 / 0.200 / 0.650` | `0.160 / 0.220 / 0.850` | `0.190 / 0.260 / 1.000` |
| `plainLetter` (11) | `0.000 / 0.080 / 0.350` | `0.000 / 0.120 / 0.450` | `0.000 / 0.160 / 0.600` |
| `qalqalah` (8) duration table | `0.040 / 0.120 / 0.350` *(all speeds)* | — | — |

Status outcome:
- `measuredSeconds < minSeconds` -> `TajweedDurationStatus.underheld`
- `measuredSeconds > maxSeconds` -> `TajweedDurationStatus.overheld`
- Otherwise -> `TajweedDurationStatus.valid`

---

## 3. How Grading Works Under the Hood

### Active Model Heads
`TajweedTakeDecoder` strictly uses 3 model outputs (`TajweedTakeDecoder.activeHeads`):
1. **`log_probs`**: Decoded CTC tokens, `firstMs`/`lastMs` timings, and `topK` alternative character probabilities (`altProbs`) used for acoustic confusion tolerance.
2. **`attr_qalqalah`**: 3-class frame probabilities; `P(burst)` combines `at(f, 1) + at(f, 2)` and takes the best 12-frame (`240 ms`) mean inside `[e+2, e+14)` clamped before the next non-control token.
3. **`conf`**: Token confidence score (`confScore`) used in structural consonant gating.

### Bidirectional CTC Blank Attribution (`SpanDurationCalculator`)
CTC collapses held sounds into brief emission spikes surrounded by `<blk>` frames (`>= 0.040 s` gaps):
- **Madd (`1..7`):** `baseDuration + shareAfter(continuationGap)`, with `maxGap = 2.50 s` for `ruleId` in `{4, 5, 6, 7}` / `goldenLen >= 6` and `1.25 s` otherwise.
- **Shaddah (`9`) & Ghunnah (`10`):** Captures both preceding closure/transition (`_closureGap`, `< 1.25 s`) and trailing prolongation (`_continuationGap`, `< 1.25 s`):
  `baseDuration + min(1.25, beforeShare + afterShare)`.
- **Adjacent held spans:** Shared gaps are split proportionally to each span's `targetSeconds` (`_shareBeforeGap` / `_shareAfterGap`).
- **Word-end Waqf pause (`nullOnPause: true`):** If a word-ending held span is followed by a gap `>= maxGap` (silence/pause after word), duration returns `null` rather than failing the user for pausing.

### Streaming Frontier Holding (`HeldFrontierShield`)
Before committing `skip == 0` on non-final partial chunks, `DictationSequencer` calls `HeldFrontierShield.shouldHold(...)` so a word is not graded before the reciter finishes phonating it:
- **Qalqalah post-burst window:** Holds commit until `0.360 s` has elapsed after an active Qalqalah token's end timestamp so the post-release window in `attr_qalqalah` is populated.
- **Frontier held sound (Madd / Ghunnah / Shaddah):** When all incoming ASR chars for the word are consumed at the frontier, waits up to `min(2.0, max(targetSeconds + 0.15, 0.45))` seconds from token onset (unless the match frontier is a non-canonical alternate variant).
- **Deleted terminal vowel:** Holds for `0.300 s` when `checkTashkeel` is enabled and the trailing short vowel was deleted, giving the final vowel a chance to arrive in the next chunk.
- On `TranscriptionResult.isFinal == true` (session finish), the frontier shield is bypassed and pending words commit immediately.

### Qalqalah Burst Grading
When `TajweedConfig.checkQalqalah` is `true` and a span has `isQalqalah`:
- `TajweedConfig.qalqalahTau` **must** be set (otherwise `QuranTarteelErrorCode.missingCalibrationThreshold` is thrown).
- Retrieve it from the SDK via `TajweedTakeDecoder.resolveValidatedQalqalahTau(model)` or `requireValidatedQalqalahTau(model)`.
- Emits a `ReciterError` (`errorType: ErrorCategory.tajweed`, `expectedRule: QalqalahRule`) if `spanAcoustics.qalqalahScore < qalqalahTau`.

---

## 4. `TajweedConfig` Rule Toggles

All checks default to `true`; `const TajweedConfig.none()` disables all 7 flags (word-tracking only):

| Flag | Default | Controls |
| :--- | :---: | :--- |
| `checkMadd` | `true` | Duration grading & missing held-sound grading on rules `1..7`. |
| `checkTashkeel` | `true` | Short vowel (`a`, `i`, `u`) mismatches (`ErrorCategory.tashkeel`), skipping pure terminal vowel drops (common at Waqf). |
| `checkGhunnah` | `true` | Duration & missing-sound grading on rule `10`. |
| `checkShaddah` | `true` | Duration & missing-sound grading on rule `9`. |
| `checkQalqalah` | `true` | Neural burst grading via `attr_qalqalah` vs `qalqalahTau` on rule `8`. |
| `checkLetterSwap` | `true` | Consonant deletion/replacement errors (`ErrorCategory.normal`) within matched words. |
| `checkPlainLetters` | `true` | Duration overhold/underhold on non-tajweed `plainLetter` (`11`) spans. |
| `qalqalahTau` | `null` | Calibrated `attr_qalqalah` threshold; required if `checkQalqalah` hits an active Qalqalah site. |

---

## 5. Interpreting `WordMatchedEvent` & `ReciterError`

`scorer.onWordEvaluated` emits one `WordMatchedEvent` per committed word:

| `WordEvaluationVerdict` | `isRight` | Meaning |
| :--- | :---: | :--- |
| `correct` | `true` | Matched within `MatchingPolicy` and passed enabled Tajweed checks. |
| `tajweedWarning` | `true` | Word recognized (`wordId` advances), with 1+ diagnostics in `tajweedErrors`. |
| `skipped` | `false` | Word skipped over when reciter matched `skip` words ahead (`score: 0.0`, `SpeechErrorType.delete`). |

Inside `event.tajweedErrors` (`List<ReciterError>?`), errors are sorted by `priority` (`0..6`) and deduplicated:
- **Priority `0` (`ErrorCategory.normal`):** Consonant deletion/swap (`SpeechErrorType.delete` / `replace`).
- **Priority `1` (`ErrorCategory.tashkeel`):** Short vowel error (`delete` / `replace`).
- **Priority `2..5` (`ErrorCategory.tajweed`):**
  - `2`: Madd (`1..7`) — `durationStatus` (`underheld` / `overheld`), plus `expectedDuration` & `actualDuration` in seconds.
  - `3`: Ghunnah (`10`)
  - `4`: Shaddah (`9`)
  - `5`: Qalqalah (`8`) — `durationStatus: underheld` when `qalqalahScore < qalqalahTau`.
- **Priority `6`:** Other / `plainLetter` overhold (`ErrorCategory.tajweed`).
