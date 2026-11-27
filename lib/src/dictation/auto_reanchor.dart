// lib/src/dictation/auto_reanchor.dart
// Forward-only fuzzy re-anchoring across a Surah when dictation stalls past threshold.

import 'dart:math';

import '../config.dart';
import '../search/fuzzy_matcher.dart';

/// Candidate forward jump target identified by [AutoReanchorFinder].
class ReanchorCandidate {
  final int wordIndex;
  final int dist;
  final int probeOffset;

  const ReanchorCandidate({
    required this.wordIndex,
    required this.dist,
    required this.probeOffset,
  });
}

/// Searches strictly forward within the target Surah while guarding against
/// Mutashabihat (ambiguous similar passages).
class AutoReanchorFinder {
  /// Maps a character index in [fullPhonemes] to its enclosing global word index.
  static int findWordIndexAtPhonemeOffset(
    List<int> wordBoundaries,
    int wordCount,
    int charOffset,
  ) {
    if (wordBoundaries.isEmpty) return 0;
    int low = 0;
    int high = wordBoundaries.length - 1;
    int found = 0;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (wordBoundaries[mid] <= charOffset) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return found.clamp(0, wordCount);
  }

  static ReanchorCandidate? _probeQueryWindow({
    required String queryText,
    required int offset,
    required String fullPhonemes,
    required List<int> wordBoundaries,
    required int wordCount,
    required int targetWordCursor,
    required TrackerConfig config,
  }) {
    final reanchor = config.reanchor;
    final int qLen = queryText.length;
    final int minRequiredLen = config.reanchorStallThreshold > 0
        ? min(reanchor.maxMinQueryLen, config.reanchorStallThreshold)
        : reanchor.minQueryLen;
    if (qLen < minRequiredLen) return null;

    final int maxDist = (qLen * reanchor.maxDistRatio).toInt();
    final List<FuzzyMatch> matches =
        findNearMatches(queryText, fullPhonemes, maxDist);
    if (matches.isEmpty) return null;

    final List<({int wordIndex, int dist})> candidateWords = [];
    for (final m in matches) {
      final int w = findWordIndexAtPhonemeOffset(
        wordBoundaries,
        wordCount,
        m.start,
      );
      if (w > targetWordCursor) {
        candidateWords.add((wordIndex: w, dist: m.dist));
      }
    }
    if (candidateWords.isEmpty) return null;

    candidateWords.sort((a, b) {
      if (a.dist != b.dist) return a.dist.compareTo(b.dist);
      return a.wordIndex.compareTo(b.wordIndex);
    });
    final best = candidateWords[0];

    for (int i = 1; i < candidateWords.length; i++) {
      final c = candidateWords[i];
      if ((c.wordIndex - best.wordIndex).abs() > reanchor.ambiguityWordGap &&
          (c.dist - best.dist) < reanchor.ambiguityDistGap) {
        return null;
      }
    }

    return ReanchorCandidate(
      wordIndex: best.wordIndex,
      dist: best.dist,
      probeOffset: offset,
    );
  }

  /// Attempts to locate an unambiguous forward match for [rawQuery] strictly after
  /// [targetWordCursor], returning `null` if no unique match meets thresholds.
  static ReanchorCandidate? findForwardReanchor({
    required String rawQuery,
    required String fullPhonemes,
    required List<int> wordBoundaries,
    required int wordCount,
    required int targetWordCursor,
    required TrackerConfig config,
  }) {
    final reanchor = config.reanchor;

    final int fullLen = min(reanchor.fullQueryMaxLen, rawQuery.length);
    var result = _probeQueryWindow(
      queryText: rawQuery.substring(0, fullLen),
      offset: 0,
      fullPhonemes: fullPhonemes,
      wordBoundaries: wordBoundaries,
      wordCount: wordCount,
      targetWordCursor: targetWordCursor,
      config: config,
    );

    if (result == null && fullLen > reanchor.frontQueryMaxLen) {
      result = _probeQueryWindow(
        queryText: rawQuery.substring(0, reanchor.frontQueryMaxLen),
        offset: 0,
        fullPhonemes: fullPhonemes,
        wordBoundaries: wordBoundaries,
        wordCount: wordCount,
        targetWordCursor: targetWordCursor,
        config: config,
      );
    }

    if (result == null && rawQuery.length > reanchor.tailQueryMaxLen) {
      final int tailLen = min(reanchor.tailQueryMaxLen, rawQuery.length);
      final int tailOffset = rawQuery.length - tailLen;
      result = _probeQueryWindow(
        queryText: rawQuery.substring(tailOffset),
        offset: tailOffset,
        fullPhonemes: fullPhonemes,
        wordBoundaries: wordBoundaries,
        wordCount: wordCount,
        targetWordCursor: targetWordCursor,
        config: config,
      );
    }

    return result;
  }
}
