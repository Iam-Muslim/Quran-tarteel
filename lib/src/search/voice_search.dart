// lib/src/search/voice_search.dart
// Pure-Dart global phonetic index (Myers bit-parallel) and real-time voice search controller.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../core_types.dart';
import '../reference/quran_repository.dart';
import '../reference/zfx_loader.dart';
import 'fuzzy_matcher.dart';
import 'search_transport_io.dart'
    if (dart.library.js_interop) 'search_transport_web.dart';

class PhonemesSearchSpan {
  final int surahIdx;
  final int ayahIdx;
  final int wordIdx;
  final int phonemesIdx;

  const PhonemesSearchSpan({
    required this.surahIdx,
    required this.ayahIdx,
    required this.wordIdx,
    required this.phonemesIdx,
  });
}

class PhonemesSearchResult {
  final PhonemesSearchSpan start;
  final PhonemesSearchSpan end;
  final PhonemesSearchSpan mid;
  final int distance;

  const PhonemesSearchResult({
    required this.start,
    required this.end,
    required this.mid,
    required this.distance,
  });
}

class PhoneticSearch {
  late Uint16List _indexArray;
  late String _refPhNorm;
  Uint8List? _coreCodeMask;
  bool _isLoaded = false;
  final SearchWorkerTransport _worker = SearchWorkerTransport();

  bool get isLoaded => _isLoaded;
  Uint8List? get coreCodeMask => _coreCodeMask;

  Future<void> load(TajweedFormerReferenceReader reader) async {
    if (_isLoaded) return;

    final StringBuffer phBuffer = StringBuffer();
    final List<int> coords = [];
    reader.forEachNonControlToken((surah, ayah, wordIdx, tokStr) {
      phBuffer.write(tokStr);
      for (int c = 0; c < tokStr.length; c++) {
        coords.add(surah);
        coords.add(ayah);
        coords.add(wordIdx);
      }
    });

    _refPhNorm = phBuffer.toString();
    _indexArray = Uint16List.fromList(coords);
    _coreCodeMask = buildCoreCodeMask(reader.tokens);
    await _worker.start(_refPhNorm);
    _isLoaded = true;
  }

  static Uint8List buildCoreCodeMask(PhonemeVocabulary tokens) {
    final arr = Uint8List(2048);
    for (final tok in tokens.names) {
      if (PhoneticSymbols.isControlToken(tok)) continue;
      for (int i = 0; i < tok.length; i++) {
        final code = tok.codeUnitAt(i);
        if (code < 2048) arr[code] = 1;
      }
    }
    return arr;
  }

  static String normalizeQuery(
    String query, {
    required Uint8List coreCodeMask,
  }) {
    if (query.isEmpty) return '';
    final StringBuffer parts = StringBuffer();
    int prevCode = -1;
    int prevPrevCode = -1;

    for (int i = 0; i < query.length; i++) {
      final int code = query.codeUnitAt(i);
      if (code < 2048 && coreCodeMask[code] == 1) {
        if (PhoneticSymbols.isVowelChar(code)) {
          if (prevCode == code && prevPrevCode == code) continue;
          parts.writeCharCode(code);
          prevPrevCode = prevCode;
          prevCode = code;
        } else {
          if (code != prevCode) {
            parts.writeCharCode(code);
            prevPrevCode = prevCode;
            prevCode = code;
          }
        }
      }
    }
    return parts.toString();
  }

  PhonemesSearchSpan _refIdxToSpan(int refIdx) {
    if (refIdx < 0 || refIdx >= _refPhNorm.length) {
      throw RangeError.range(refIdx, 0, _refPhNorm.length - 1, 'refIdx');
    }
    final int rowOffset = refIdx * 3;
    return PhonemesSearchSpan(
      surahIdx: _indexArray[rowOffset + 0],
      ayahIdx: _indexArray[rowOffset + 1],
      wordIdx: _indexArray[rowOffset + 2],
      phonemesIdx: refIdx,
    );
  }

  Future<List<PhonemesSearchResult>> searchIsolated(
    String query, {
    double errorRatio = 0.1,
  }) async {
    final mask = _coreCodeMask;
    if (!_isLoaded || mask == null) {
      throw const QuranTarteelException(QuranTarteelErrorCode.uninitialized);
    }

    final String normQuery = normalizeQuery(query, coreCodeMask: mask);
    if (normQuery.isEmpty) return const [];

    final int maxEdits = (normQuery.length * errorRatio).toInt();
    final List<FuzzyMatch> outs = await _worker.search(normQuery, maxEdits);
    if (outs.isEmpty) return const [];

    final List<PhonemesSearchResult> results = [
      for (final out in outs)
        PhonemesSearchResult(
          start: _refIdxToSpan(out.start),
          end: _refIdxToSpan(out.end - 1),
          mid: _refIdxToSpan((out.start + out.end - 1) ~/ 2),
          distance: out.dist,
        ),
    ];

    results.sort((a, b) => a.distance.compareTo(b.distance));
    return results;
  }

  void dispose() {
    _isLoaded = false;
    _worker.dispose();
  }
}

class AyahSearchMatch {
  final int surah;
  final int ayah;
  final int startAyah;
  final int endAyah;
  final double score;
  final int distance;
  final int wordIdx;
  final int startWordIdx;
  final int endWordIdx;
  final String? textPhoneme;

  bool get isMultiAyah => startAyah != endAyah;

  const AyahSearchMatch({
    required this.surah,
    required this.ayah,
    required this.score,
    required this.distance,
    this.wordIdx = 0,
    this.startWordIdx = 0,
    this.endWordIdx = 0,
    int? startAyah,
    int? endAyah,
    this.textPhoneme,
  })  : startAyah = startAyah ?? ayah,
        endAyah = endAyah ?? ayah;
}

class VoiceSearchResult {
  final String queryText;
  final List<AyahSearchMatch> candidates;
  final bool isUnique;
  final AyahSearchMatch? topMatch;

  const VoiceSearchResult({
    required this.queryText,
    required this.candidates,
    required this.isUnique,
    this.topMatch,
  });

  bool get hasCandidates => candidates.isNotEmpty;
}

class VoiceSearchController {
  final QuranRepository repository;
  final List<String> ignorePrefixes;
  final bool useAdaptiveErrorRatio;
  final bool allowSuffixFallback;

  PhoneticSearch? _search;
  List<String>? _normalizedPrefixes;

  final StreamController<bool> _indexLoadingController =
      StreamController<bool>.broadcast();
  final StreamController<VoiceSearchResult?> _resultsController =
      StreamController<VoiceSearchResult?>.broadcast();

  Stream<bool> get onIndexLoadingChanged => _indexLoadingController.stream;
  Stream<VoiceSearchResult?> get onSearchResult => _resultsController.stream;

  bool _isIndexLoading = false;
  bool get isIndexLoading => _isIndexLoading;
  bool get isLoaded => _search?.isLoaded ?? false;

  VoiceSearchResult? _currentResult;
  VoiceSearchResult? get currentResult => _currentResult;

  Future<void>? _loadFuture;
  bool _isSearching = false;
  String? _queuedText;
  int _sessionEpoch = 0;

  VoiceSearchController({
    required this.repository,
    this.ignorePrefixes = const [],
    this.useAdaptiveErrorRatio = false,
    this.allowSuffixFallback = false,
  });

  Future<void> preloadIndex() {
    if (_search != null) return Future.value();
    if (_loadFuture != null) return _loadFuture!;

    _loadFuture = () async {
      _setLoading(true);
      try {
        if (!repository.isLoaded) {
          throw const QuranTarteelException(QuranTarteelErrorCode.uninitialized);
        }
        final search = PhoneticSearch();
        await search.load(repository.reference);
        final mask = search.coreCodeMask!;
        _normalizedPrefixes = [
          for (final p in ignorePrefixes)
            if (p.isNotEmpty) PhoneticSearch.normalizeQuery(p, coreCodeMask: mask),
        ];
        _search = search;
      } catch (_) {
        _search = null;
        rethrow;
      } finally {
        _setLoading(false);
        _loadFuture = null;
      }
    }();
    return _loadFuture!;
  }

  void _setLoading(bool loading) {
    _isIndexLoading = loading;
    if (!_indexLoadingController.isClosed) {
      _indexLoadingController.add(loading);
    }
  }

  void _emitResult(VoiceSearchResult? result) {
    _currentResult = result;
    if (!_resultsController.isClosed) {
      _resultsController.add(result);
    }
  }

  void clear() {
    _sessionEpoch++;
    _emitResult(null);
    _queuedText = null;
    _isSearching = false;
  }

  Future<void> startSearch() async {
    _sessionEpoch++;
    clear();
    await preloadIndex();
  }

  Future<VoiceSearchResult?> processRealtime(
    String partialText, {
    double errorRatio = 0.20,
    int minLength = 6,
    int maxCandidates = 8,
  }) async {
    final mask = _search?.coreCodeMask;
    if (_search == null || mask == null) {
      throw const QuranTarteelException(QuranTarteelErrorCode.uninitialized);
    }

    final normText = PhoneticSearch.normalizeQuery(
      partialText,
      coreCodeMask: mask,
    );
    if (normText.length < minLength) return null;

    if (_isSearching) {
      _queuedText = normText;
      return null;
    }

    _isSearching = true;
    final int epoch = _sessionEpoch;
    VoiceSearchResult? uniqueResult;

    try {
      String textToSearch = normText;

      while (true) {
        if (_sessionEpoch != epoch) return null;

        final searchResult = await _executeSearch(
          textToSearch,
          errorRatio: errorRatio,
          maxCandidates: maxCandidates,
        );

        if (_sessionEpoch != epoch) return null;

        if (searchResult != null) {
          _emitResult(searchResult);
          if (searchResult.isUnique && searchResult.topMatch != null) {
            uniqueResult = searchResult;
            break;
          }
        }

        if (_queuedText != null) {
          textToSearch = _queuedText!;
          _queuedText = null;
        } else {
          break;
        }
      }
    } finally {
      _isSearching = false;
    }

    return uniqueResult;
  }

  Future<VoiceSearchResult?> stopSearch(
    String finalAsrText, {
    double errorRatio = 0.22,
    int maxCandidates = 8,
    bool requireUnique = false,
  }) async {
    final mask = _search?.coreCodeMask;
    if (_search == null || mask == null) {
      throw const QuranTarteelException(QuranTarteelErrorCode.uninitialized);
    }

    final int epoch = _sessionEpoch;
    final normText = PhoneticSearch.normalizeQuery(
      finalAsrText,
      coreCodeMask: mask,
    );

    if (normText.length < 4) {
      _emitResult(null);
      return null;
    }

    final searchResult = await _executeSearch(
      normText,
      errorRatio: errorRatio,
      maxCandidates: maxCandidates,
    );

    if (_sessionEpoch != epoch) return null;

    if (searchResult == null || searchResult.candidates.isEmpty) {
      _emitResult(null);
      return null;
    }

    _emitResult(searchResult);

    if (requireUnique && !searchResult.isUnique) {
      return null;
    }

    return searchResult;
  }

  static double _adaptiveErrorRatio(int qLen, {required double baseRatio}) {
    if (qLen < 16) return 0.15;
    if (qLen < 28) return 0.20;
    return baseRatio.clamp(0.20, 0.25);
  }

  Future<VoiceSearchResult?> _executeSearch(
    String text, {
    required double errorRatio,
    required int maxCandidates,
  }) async {
    final mask = _search!.coreCodeMask!;
    final String normText = PhoneticSearch.normalizeQuery(
      text,
      coreCodeMask: mask,
    );
    final int qLen = normText.length;
    if (qLen < 4) return null;

    String textToSearch = normText;
    final prefixes = _normalizedPrefixes;
    if (prefixes != null && textToSearch.length > 18) {
      for (final prefix in prefixes) {
        if (prefix.isEmpty) continue;
        final int maxDist = (prefix.length * 0.15).ceil().clamp(1, 4);
        final matches = findNearMatches(prefix, textToSearch, maxDist);
        if (matches.isNotEmpty && matches.first.start <= 3) {
          final suf = textToSearch.substring(matches.first.end).trim();
          if (suf.length >= 6) {
            textToSearch = suf;
          }
        }
      }
    }

    final int searchLen = textToSearch.length;
    final double effectiveRatio = useAdaptiveErrorRatio
        ? _adaptiveErrorRatio(searchLen, baseRatio: errorRatio)
        : errorRatio;

    List<PhonemesSearchResult> rawMatches =
        await _search!.searchIsolated(textToSearch, errorRatio: effectiveRatio);

    if (rawMatches.isEmpty && textToSearch != normText) {
      rawMatches =
          await _search!.searchIsolated(normText, errorRatio: effectiveRatio);
    }

    if (allowSuffixFallback && rawMatches.isEmpty && searchLen >= 12) {
      final List<int> probeCuts = [
        (searchLen * 0.25).toInt(),
        (searchLen * 0.45).toInt(),
        (searchLen * 0.65).toInt(),
      ];
      for (final cut in probeCuts) {
        final suffix = textToSearch.substring(cut).trim();
        if (suffix.length >= 8) {
          final double sufRatio = useAdaptiveErrorRatio
              ? _adaptiveErrorRatio(suffix.length, baseRatio: errorRatio)
              : errorRatio;
          final suffixMatches =
              await _search!.searchIsolated(suffix, errorRatio: sufRatio);
          if (suffixMatches.isNotEmpty) {
            rawMatches = suffixMatches;
            break;
          }
        }
      }
    }

    if (rawMatches.isEmpty) return null;

    final Map<String, PhonemesSearchResult> bestPerAyah = {};
    for (final r in rawMatches) {
      final key = '${r.mid.surahIdx}:${r.mid.ayahIdx}';
      final existing = bestPerAyah[key];
      if (existing == null || r.distance < existing.distance) {
        bestPerAyah[key] = r;
      }
    }

    final sorted = bestPerAyah.values.toList()
      ..sort((a, b) => a.distance.compareTo(b.distance));

    final List<AyahSearchMatch> candidates = [];
    for (final r in sorted.take(maxCandidates)) {
      final int s = r.mid.surahIdx;
      final int a = r.mid.ayahIdx;
      final QuranVerse verse = repository.getVerse(s, a);

      final double score =
          (1.0 - (r.distance / max(1, searchLen))).clamp(0.0, 1.0);

      int startAyah = r.start.ayahIdx;
      int endAyah = r.end.ayahIdx;
      if (r.start.surahIdx != r.end.surahIdx) {
        if (s == r.start.surahIdx) {
          endAyah = r.mid.ayahIdx;
        } else {
          startAyah = 1;
        }
      }

      candidates.add(
        AyahSearchMatch(
          surah: s,
          ayah: a,
          startAyah: startAyah,
          endAyah: endAyah,
          score: score,
          distance: r.distance,
          wordIdx: r.mid.wordIdx,
          startWordIdx: r.start.wordIdx,
          endWordIdx: r.end.wordIdx,
          textPhoneme: verse.textPhoneme,
        ),
      );
    }

    if (candidates.isEmpty) return null;

    bool isUnique = false;
    if (candidates.length == 1) {
      final int d0 = candidates[0].distance;
      if (d0 <= 1 || (d0 / max(1, searchLen)) <= 0.12) {
        isUnique = true;
      }
    } else if (candidates.length > 1) {
      final int d0 = candidates[0].distance;
      final int d1 = candidates[1].distance;
      final int gap = d1 - d0;

      if (d0 == 0) {
        final int minGap = (searchLen >= 18) ? 2 : 3;
        isUnique = gap >= minGap;
      } else if (d0 <= 1 && searchLen >= 18) {
        isUnique = gap >= 3;
      }
    }

    return VoiceSearchResult(
      queryText: text,
      candidates: candidates,
      isUnique: isUnique,
      topMatch: candidates.first,
    );
  }

  void dispose() {
    _search?.dispose();
    _resultsController.close();
    _indexLoadingController.close();
  }
}
