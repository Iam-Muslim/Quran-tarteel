// lib/src/reference/quran_repository.dart
// Strict in-memory Surah/Ayah reference cache decoded directly from expected_tj3.zfx.

import 'dart:typed_data';

import '../core_types.dart';
import 'zfx_loader.dart';

/// Strict in-memory cache of Surah/Ayah phonetic words and Tajweed rules decoded
/// directly from `expected_tj3.zfx` bytes and [PhonemeVocabulary].
class QuranRepository {
  TajweedFormerReferenceReader? _reference;
  PhonemeVocabulary? _vocabulary;

  final Map<int, List<QuranVerse>> _surahCache = {};
  final Map<int, List<ContinuousQuranWord>> _surahWordsCache = {};
  final Map<int, Map<int, int>> _ayahStartWordIndexCache = {};

  QuranRepository();

  /// Constructs a repository and immediately loads [bytes] with [vocabulary].
  factory QuranRepository.fromZfxBytes(
    Uint8List bytes, {
    required PhonemeVocabulary vocabulary,
    String? expectedTokensSha256,
  }) {
    final repo = QuranRepository();
    repo.loadBytes(
      bytes,
      vocabulary: vocabulary,
      expectedTokensSha256: expectedTokensSha256,
    );
    return repo;
  }

  /// Whether `expected_tj3.zfx` reference data has been loaded.
  bool get isLoaded => _reference != null;

  /// Active token vocabulary paired with the loaded reference data.
  PhonemeVocabulary? get vocabulary => _vocabulary;

  /// Direct reader for the loaded `expected_tj3.zfx` binary.
  /// Throws [QuranTarteelException] with [QuranTarteelErrorCode.uninitialized] before load.
  TajweedFormerReferenceReader get reference {
    final ref = _reference;
    if (ref == null) {
      throw const QuranTarteelException(QuranTarteelErrorCode.uninitialized);
    }
    return ref;
  }

  /// Total number of Surahs present in the loaded dataset.
  int get surahCount => reference.surahs;

  /// Loads `expected_tj3.zfx` directly from [bytes] and [vocabulary].
  ///
  /// Throws [StateError] if already loaded unless [forceReload] is `true`.
  /// When [expectedTokensSha256] is provided, throws [QuranTarteelException]
  /// (`invalidReferenceData`) if the dataset's header SHA-256 does not match.
  void loadBytes(
    Uint8List bytes, {
    required PhonemeVocabulary vocabulary,
    String? expectedTokensSha256,
    bool forceReload = false,
  }) {
    if (_reference != null && !forceReload) {
      throw StateError(
        'QuranRepository is already loaded. Pass forceReload: true to replace.',
      );
    }

    final reader = TajweedFormerReferenceReader.fromBytes(
      bytes,
      tokens: vocabulary,
    );

    if (expectedTokensSha256 != null &&
        !reader.matchesTokensSha256(expectedTokensSha256)) {
      throw QuranTarteelException(
        QuranTarteelErrorCode.invalidReferenceData,
        'tokens_sha256 mismatch: expected $expectedTokensSha256, '
        'found ${reader.tokensSha256Hex}',
      );
    }

    _surahCache.clear();
    _surahWordsCache.clear();
    _ayahStartWordIndexCache.clear();
    _vocabulary = vocabulary;
    _reference = reader;
  }

  void _ensureSurahParsed(int surah) {
    final ref = reference;
    RangeError.checkValueInInterval(surah, 1, ref.surahs, 'surah');
    if (_surahCache.containsKey(surah)) return;

    final int totalAyahs = ref.ayahCount(surah);
    final List<QuranVerse> verses = [];

    for (int ayah = 1; ayah <= totalAyahs; ayah++) {
      final ayahUnits = ref.getAyahUnits(surah, ayah);
      final composed = ReferenceComposer.compose(ayahUnits, reader: ref);
      final phonemeWords = composed.map((w) => w.phoneme).toList();
      final wordRules = composed.map((w) => w.rules).toList();
      final wordCharClasses =
          composed.map((w) => w.charRuleClasses).toList();
      final wordForms = composed.map((w) => w.alternateForms).toList();

      verses.add(
        QuranVerse(
          surah: surah,
          ayah: ayah,
          textPhoneme: phonemeWords.join(''),
          phonemeWords: phonemeWords,
          wordRules: wordRules,
          wordCharClasses: wordCharClasses,
          wordForms: wordForms,
        ),
      );
    }

    _surahCache[surah] = verses;
  }

  /// Returns all composed verses for 1-based [surah].
  List<QuranVerse> getSurah(int surah) {
    _ensureSurahParsed(surah);
    return _surahCache[surah]!;
  }

  /// Returns the flattened continuous word sequence across 1-based [surah].
  List<ContinuousQuranWord> getSurahWords(int surah) {
    _ensureSurahParsed(surah);
    final cached = _surahWordsCache[surah];
    if (cached != null) return cached;

    final verses = _surahCache[surah]!;
    final List<ContinuousQuranWord> words = [];
    final Map<int, int> ayahStartMap = {};
    int globalIdx = 0;

    for (final verse in verses) {
      ayahStartMap[verse.ayah] = globalIdx;
      for (int i = 0; i < verse.phonemeWords.length; i++) {
        words.add(
          ContinuousQuranWord(
            globalIndex: globalIdx++,
            surah: verse.surah,
            ayah: verse.ayah,
            wordInAyah: i,
            phoneme: verse.phonemeWords[i],
            rules: verse.wordRules[i],
            charRuleClasses: verse.wordCharClasses[i],
            alternateForms: verse.wordForms[i],
          ),
        );
      }
    }

    _ayahStartWordIndexCache[surah] = ayahStartMap;
    _surahWordsCache[surah] = words;
    return words;
  }

  /// Returns the 0-based global word offset within [surah] where 1-based [ayah] starts.
  int getAyahStartGlobalIndex(int surah, int ayah) {
    getSurahWords(surah);
    final int? idx = _ayahStartWordIndexCache[surah]?[ayah];
    if (idx == null) {
      throw RangeError.value(ayah, 'ayah');
    }
    return idx;
  }

  /// Returns the 0-based global word offset within [surah] for `(ayah, wordIndex)`.
  int getWordGlobalIndex(int surah, int ayah, int wordIndex) {
    final verse = getVerse(surah, ayah);
    RangeError.checkValueInInterval(
      wordIndex,
      0,
      verse.wordCount - 1,
      'wordIndex',
    );
    return getAyahStartGlobalIndex(surah, ayah) + wordIndex;
  }

  /// Returns the composed [QuranVerse] for 1-based `(surah, ayah)`.
  QuranVerse getVerse(int surah, int ayah) {
    final verses = getSurah(surah);
    RangeError.checkValueInInterval(ayah, 1, verses.length, 'ayah');
    return verses[ayah - 1];
  }

  /// Returns the number of Uthmani words in 1-based `(surah, ayah)`.
  int getAyahWordCount(int surah, int ayah) =>
      getVerse(surah, ayah).wordCount;
}
