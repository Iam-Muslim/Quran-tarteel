# Voice Search & Auto-Reanchor Guide

## 1. Voice Search (`VoiceSearchController`)

`VoiceSearchController` searches all 6,236 ayahs in an off-main-thread worker (`SearchWorkerTransport`: `Isolate` on IO, in-process on Web) using `PhoneticSearch`.

### How Indexing & Normalization Work
1. `preloadIndex()` iterates every non-control token in `expected_tj3.zfx` (`<blk>`, `|`, `<foreign>` skipped), builds a contiguous global phoneme string paired with `(surah, ayah, wordIdx)` coordinates, and builds a 2048-code-unit `coreCodeMask` from the vocabulary.
2. `PhoneticSearch.normalizeQuery(query, coreCodeMask: mask)` filters out non-vocab chars, collapses consecutive identical consonants (`cc -> c`), and caps consecutive identical vowels at 2 (`aaa -> aa`, preserving Madd length while preventing long-hold bloat).
3. `fuzzy_matcher.dart` runs Gene Myers' 64-bit bit-parallel approximate string search (`findNearMatches`) for queries `<= 64` chars, falling back to DP for longer queries, then refines each match start in reverse so minimal-distance spans are exact.

### Setup & Live Recite-to-Navigate Flow

```dart
final search = VoiceSearchController(
  repository: repo,
  // Optional: strip Isti'adha / Basmala prefixes when user starts with them
  ignorePrefixes: const [
    'a3uuTHubillaahiminashshayTaanirrajiim', // normalized against coreCodeMask at load time
  ],
  useAdaptiveErrorRatio: true,
  allowSuffixFallback: true,
);

await search.preloadIndex();

search.onIndexLoadingChanged.listen((loading) { /* spinner state */ });
search.onSearchResult.listen((VoiceSearchResult? result) {
  if (result == null) return;
  if (result.isUnique && result.topMatch != null) {
    final m = result.topMatch!;
    // Navigate directly to (m.surah, m.ayah)
  } else {
    // Show result.candidates list
  }
});

// New search session:
await search.startSearch();

// On each ASR chunk while listening (use wordOnlyHeads to avoid unneeded Qalqalah overhead):
final session = await model.listen(
  options: const TajweedSessionOptions(heads: TajweedTakeDecoder.wordOnlyHeads),
);
session.chunks.listen((chunk) {
  final text = TajweedTakeDecoder.formatDecodedText(chunk.decoded.tokens);
  if (text.isNotEmpty) {
    search.processRealtime(text);
  }
});

// On stop / final transcript:
final finalResult = await search.stopSearch(lastText, requireUnique: false);
```

### Constructor & Call Options

| Option | Default | Behavior |
| :--- | :--- | :--- |
| `ignorePrefixes` | `const []` | Normalized once during `preloadIndex()`. If query length `> 18` and a prefix fuzzy-matches near index `0..3` (distance `<= 15%`, clamped `1..4`), searches the remaining suffix first (falls back to full query if no match). |
| `useAdaptiveErrorRatio` | `false` | Overrides `errorRatio` by normalized query length: `< 16` -> `0.15`, `< 28` -> `0.20`, `>= 28` -> `errorRatio.clamp(0.20, 0.25)`. |
| `allowSuffixFallback` | `false` | If query length `>= 12` yields 0 matches, retries substrings starting at `25%`, `45%`, and `65%` of the query (requiring suffix length `>= 8`). |
| `processRealtime(...)` | `errorRatio = 0.20`, `minLength = 6`, `maxCandidates = 8` | Coalesces concurrent queries (`_queuedText`) so main thread never queues stale searches; returns early once `isUnique` becomes `true`. |
| `stopSearch(...)` | `errorRatio = 0.22`, `maxCandidates = 8`, `requireUnique = false` | Minimum normalized length `4`; if `requireUnique: true` and ambiguous, returns `null` (while still updating `onSearchResult`). |

### `VoiceSearchResult` & `AyahSearchMatch`

- Candidates are deduplicated to best match per `(surah, ayah)` sorted by lowest edit `distance`, capped at `maxCandidates`.
- **Single candidate uniqueness:** `isUnique = true` when `distance <= 1` or `distance / searchLen <= 0.12`.
- **Multi-candidate uniqueness:**
  - `d0 == 0`: requires `d1 - d0 >= 2` (for `searchLen >= 18`) or `>= 3` (shorter queries).
  - `d0 <= 1` and `searchLen >= 18`: requires `d1 - d0 >= 3`.
- **`AyahSearchMatch` fields:**
  - `surah`, `ayah` (midpoint anchor), `wordIdx`
  - `startAyah`, `endAyah`, `isMultiAyah` (true when span crosses an ayah boundary; resets `startAyah = 1` if span straddles a Surah boundary)
  - `startWordIdx`, `endWordIdx`
  - `distance` (edit distance), `score` (`(1.0 - distance / searchLen).clamp(0.0, 1.0)`), `textPhoneme`

Lifecycle: call `search.clear()` between queries and `search.dispose()` when done to kill the search isolate.

---

## 2. Auto-Reanchor (`AutoReanchorFinder`)

During active recitation, minor word skips (`1..2` words) are handled immediately inside `DictationSequencer` if the skipped word + the *next* word both match within `skipThreshold` (`min(defaultMaxPathCost, skipMaxPathCost)`). When a reciter jumps further ahead in the Surah (skipping an ayah, resuming after a pause elsewhere in the Surah, etc.), local word matching stalls and unconsumed ASR characters accumulate.

### Enabling Auto-Reanchor
Auto-reanchor is **off by default** in `TrackerConfig()` / `TrackerConfig.normal()`. Enable it explicitly (or use `TrackerConfig.fast()`):

```dart
final scorer = QuranScorer(
  repository: repo,
  config: TrackerConfig(
    enableAutoReanchor: true,
    reanchorStallThreshold: 40, // default is 100 normalized phonetic chars
    reanchor: const ReanchorPolicy(),
  ),
);

scorer.onAutoReanchored.listen((AutoReanchorEvent event) {
  // UI cursor updated to event.surah, event.ayah, event.wordInAyah
  // event.previousWordIndex -> event.newWordIndex (global Surah word indices)
});
```

### Trigger Conditions & Probe Windows
Inside `DictationSequencer._attemptAutoReanchor()`:
1. Local DTW failed to match `targetWordCursor .. targetWordCursor + maxSkipWords`.
2. `config.enableAutoReanchor == true` and `unconsumedLen >= config.reanchorStallThreshold`.
3. Deduplicated per `(asrCharAnchor, segmentLength)` so the same stalled buffer isn't re-probed twice.
4. `AutoReanchorFinder.findForwardReanchor` probes up to 3 query windows against `fullPhonemes` using `findNearMatches(..., maxDist = (qLen * maxDistRatio).toInt())`:
   - **Full window:** first `min(fullQueryMaxLen, rawQuery.length)` chars (`offset = 0`)
   - **Front window** (if needed and `fullLen > frontQueryMaxLen`): first `frontQueryMaxLen` chars (`offset = 0`)
   - **Tail window** (if needed and `rawQuery.length > tailQueryMaxLen`): last `tailQueryMaxLen` chars (`offset = rawQuery.length - tailLen`) — recovers when earlier speech was noisy.
5. **Strictly forward filter:** Candidates with mapped `wordIndex <= targetWordCursor` are discarded. It never jumps backwards.
6. **Mutashabihat ambiguity guard:** Candidates are sorted by `(dist, wordIndex)`. If any competing candidate differs in position by `> ambiguityWordGap` words AND has distance within `< ambiguityDistGap` of the best match (`(c.dist - best.dist) < ambiguityDistGap`), reanchor returns `null` and waits for more reciter context instead of jumping to the wrong verse.

### `ReanchorPolicy` Reference

| Field | Default | Purpose |
| :--- | :---: | :--- |
| `minQueryLen` | `8` | Minimum probe length when `reanchorStallThreshold <= 0`. |
| `maxMinQueryLen` | `18` | Upper cap on minimum required probe length (`min(maxMinQueryLen, reanchorStallThreshold)`). |
| `maxDistRatio` | `0.22` | Max Levenshtein edit distance as a fraction of probe length. |
| `fullQueryMaxLen` | `64` | First probe window length (fits Myers 64-bit word). |
| `frontQueryMaxLen` | `36` | Shorter leading fallback probe length. |
| `tailQueryMaxLen` | `28` | Trailing fallback probe length to shed corrupted prefix audio. |
| `ambiguityWordGap` | `2` | Minimum word separation considered a distinct Mutashabihat occurrence. |
| `ambiguityDistGap` | `3` | Required edit-distance lead over a distant competing match to commit jump. |

When a jump succeeds:
- `targetWordCursor` moves to `result.wordIndex` (so words between `oldCursor` and `newWordIndex` are jumped over without emitting `skipped` red errors for every intervening word).
- Any previously committed marks at `>= targetWordCursor` are cleared so alignment resumes cleanly from the new anchor, and matching immediately continues from `asrCharAnchor += result.probeOffset`.
- Listen to `scorer.onAutoReanchored` (`AutoReanchorEvent`) to jump your UI highlight/scroll state synchronously.
