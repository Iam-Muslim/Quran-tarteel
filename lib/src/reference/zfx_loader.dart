// lib/src/reference/zfx_loader.dart
// Pure-Dart binary expected_tj3.zfx ('ZFTJEXP1') decoder, word composer, and immutable models.

import 'dart:typed_data';

import '../core_types.dart';

/// Madd duration annotation entry stored per token inside `expected_tj3.zfx`.
class MaddEntry {
  final int tokenIndex;
  final int ruleClass;
  final int allowedCounts;
  final int canonicalCount;
  final int flags;

  const MaddEntry({
    required this.tokenIndex,
    required this.ruleClass,
    required this.allowedCounts,
    required this.canonicalCount,
    required this.flags,
  });

  /// Whether this Madd annotation is anchored on a Madd letter base.
  bool get isMaddLetterBase => (flags & 1) != 0;
}

/// Raw decoded `expected_tj3.zfx` units and annotations for a single ayah.
class AyahReferenceUnits {
  final int surah;
  final int ayah;
  final List<int> units;
  final List<int> wordIndices;
  final int wordCount;
  final List<int> tokenFlags;
  final List<MaddEntry> maddEntries;
  final List<List<String>> wordForms;

  const AyahReferenceUnits({
    required this.surah,
    required this.ayah,
    required this.units,
    required this.wordIndices,
    required this.wordCount,
    this.tokenFlags = const [],
    this.maddEntries = const [],
    this.wordForms = const [],
  });
}

/// Deterministic Tajweed rule specification attached to characters within a word.
class WordTajweedRule {
  /// Rule taxonomy ID (`1..7`: Madd, `8`: Qalqalah, `9`: Shaddah, `10`: Ghunnah).
  final int ruleId;

  /// Canonical holding length in harakat (`1, 1.5, 2, 4, 6`).
  final num goldenLen;

  /// Whether Qalqalah burst evaluation applies to this rule site.
  final bool hasQalqalah;

  /// Expected Ghunnah nasalization code (`0`: none, `2`: mushaddad, `3`: ikhfaa/iqlab, `4`: idgham).
  final int ghunnaExpected;

  /// Expected Qalqalah level (`0`: none, `1`: sughra, `2`: kubra).
  final int qalqalahExpected;

  /// Bitmask of acceptable harakat durations permitted by Hafs 'an 'Asim.
  final int allowedCounts;

  const WordTajweedRule({
    required this.ruleId,
    required this.goldenLen,
    this.hasQalqalah = false,
    this.ghunnaExpected = 0,
    this.qalqalahExpected = 0,
    this.allowedCounts = 0,
  });
}

/// Composed phonetic word paired with per-character rule classes and valid pronunciation variants.
class ComposedWord {
  final String phoneme;
  final List<int> charRuleClasses;
  final List<WordTajweedRule> rules;
  final List<String> alternateForms;

  const ComposedWord({
    required this.phoneme,
    required this.charRuleClasses,
    required this.rules,
    this.alternateForms = const [],
  });
}

/// Complete composed phonetic reference and Tajweed rule metadata for a Quran verse.
class QuranVerse {
  final int surah;
  final int ayah;
  final String textPhoneme;
  final List<String> phonemeWords;
  final List<List<WordTajweedRule>> wordRules;
  final List<List<int>> wordCharClasses;
  final List<List<String>> wordForms;

  int get wordCount => phonemeWords.length;

  const QuranVerse({
    required this.surah,
    required this.ayah,
    required this.textPhoneme,
    required this.phonemeWords,
    this.wordRules = const [],
    this.wordCharClasses = const [],
    this.wordForms = const [],
  });
}

/// Continuous Surah-indexed word entry used by streaming DTW word alignment.
class ContinuousQuranWord {
  final int globalIndex;
  final int surah;
  final int ayah;
  final int wordInAyah;
  final String phoneme;
  final List<WordTajweedRule> rules;
  final List<int> charRuleClasses;
  final List<String> alternateForms;

  const ContinuousQuranWord({
    required this.globalIndex,
    required this.surah,
    required this.ayah,
    required this.wordInAyah,
    required this.phoneme,
    this.rules = const [],
    this.charRuleClasses = const [],
    this.alternateForms = const [],
  });
}

/// Pure-Dart binary reader for `expected_tj3.zfx` (`ZFTJEXP1`).
class TajweedFormerReferenceReader {
  static const int _headerSize = 160;
  static const List<int> _magic = [
    0x5A, 0x46, 0x54, 0x4A, 0x45, 0x58, 0x50, 0x31, // 'ZFTJEXP1'
  ];
  static const int _ayahRecordSize = 20;

  final Uint8List _bytes;
  final ByteData _bd;
  final PhonemeVocabulary tokens;
  final int _wordBarTokenId;
  final int? _foreignTokenId;

  late final int surahs;
  late final int totalAyahs;
  late final int totalTokens;
  late final int totalMadd;
  late final int formsBytes;

  /// Raw 32-byte SHA-256 digest of the token vocabulary stored in header bytes `72..104`.
  late final Uint8List tokensSha256;

  late final int _offAyahCounts;
  late final int _offAyahIndex;
  late final int _offTokens;
  late final int _offWords;
  late final int _offFlags;
  late final int _offMadd;
  late final int _offForms;

  late final List<int> _surahFirst;

  TajweedFormerReferenceReader._(
    this._bytes,
    this.tokens,
    this._wordBarTokenId,
    this._foreignTokenId,
  ) : _bd = ByteData.sublistView(_bytes) {
    _parse();
  }

  /// Parses an `expected_tj3.zfx` buffer and validates magic bytes, header
  /// offsets, and [tokens] structure.
  factory TajweedFormerReferenceReader.fromBytes(
    Uint8List bytes, {
    required PhonemeVocabulary tokens,
  }) {
    if (tokens.names.isEmpty || tokens.wordBar == null) {
      throw const QuranTarteelException(
        QuranTarteelErrorCode.invalidReferenceData,
      );
    }
    return TajweedFormerReferenceReader._(
      bytes,
      tokens,
      tokens.wordBar!,
      tokens.id('<foreign>'),
    );
  }

  /// Lowercase hexadecimal representation of [tokensSha256].
  String get tokensSha256Hex {
    final sb = StringBuffer();
    for (final byte in tokensSha256) {
      sb.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Returns `true` when [expectedHex] is a valid 64-char SHA-256 hex digest
  /// matching the dataset's embedded [tokensSha256].
  bool matchesTokensSha256(String expectedHex) {
    final normalized = expectedHex.trim().toLowerCase();
    if (normalized.length != 64) return false;
    return tokensSha256Hex == normalized;
  }

  String tokenName(int id) {
    RangeError.checkValidIndex(id, tokens.names, 'id');
    return tokens.names[id];
  }

  void _parse() {
    if (_bytes.length < _headerSize) {
      throw const QuranTarteelException(
        QuranTarteelErrorCode.invalidReferenceData,
      );
    }
    for (int i = 0; i < 8; i++) {
      if (_bytes[i] != _magic[i]) {
        throw const QuranTarteelException(
          QuranTarteelErrorCode.invalidReferenceData,
        );
      }
    }

    final version = _bd.getUint32(8, Endian.little);
    final headerSize = _bd.getUint32(12, Endian.little);
    final fileSize = _bd.getUint32(16, Endian.little);
    if (version != 1 || headerSize != _headerSize || fileSize != _bytes.length) {
      throw const QuranTarteelException(
        QuranTarteelErrorCode.invalidReferenceData,
      );
    }

    surahs = _bd.getUint32(20, Endian.little);
    totalAyahs = _bd.getUint32(24, Endian.little);
    totalTokens = _bd.getUint32(28, Endian.little);
    totalMadd = _bd.getUint32(32, Endian.little);
    formsBytes = _bd.getUint32(36, Endian.little);
    tokensSha256 = Uint8List.fromList(_bytes.sublist(72, 104));

    _offAyahCounts = _bd.getUint32(104, Endian.little);
    _offAyahIndex = _bd.getUint32(108, Endian.little);
    _offTokens = _bd.getUint32(112, Endian.little);
    _offWords = _bd.getUint32(116, Endian.little);
    _offFlags = _bd.getUint32(120, Endian.little);
    _offMadd = _bd.getUint32(124, Endian.little);
    _offForms = _bd.getUint32(128, Endian.little);

    _surahFirst = List<int>.filled(surahs + 1, 0);
    int acc = 0;
    for (int s = 0; s < surahs; s++) {
      _surahFirst[s] = acc;
      acc += _bd.getUint16(_offAyahCounts + 2 * s, Endian.little);
    }
    _surahFirst[surahs] = acc;

    if (acc != totalAyahs) {
      throw const QuranTarteelException(
        QuranTarteelErrorCode.invalidReferenceData,
      );
    }
  }

  int ayahCount(int surah) {
    RangeError.checkValueInInterval(surah, 1, surahs, 'surah');
    return _surahFirst[surah] - _surahFirst[surah - 1];
  }

  void forEachNonControlToken(
    void Function(int surah, int ayah, int wordIndex, String tokenStr) visit,
  ) {
    int gIdx = 0;
    for (int sIdx = 0; sIdx < surahs; sIdx++) {
      final int s = sIdx + 1;
      final int numAyahs =
          _bd.getUint16(_offAyahCounts + 2 * sIdx, Endian.little);

      for (int a = 1; a <= numAyahs; a++) {
        final int recordOffset = _offAyahIndex + gIdx * _ayahRecordSize;
        gIdx++;

        final int firstToken = _bd.getUint32(recordOffset, Endian.little);
        final int tokCount = _bd.getUint16(recordOffset + 12, Endian.little);

        for (int i = 0; i < tokCount; i++) {
          final int t = _bytes[_offTokens + firstToken + i];
          if (t == _wordBarTokenId ||
              t == tokens.blank ||
              t == _foreignTokenId) {
            continue;
          }
          final String tokStr = tokenName(t);
          final int wid = _bytes[_offWords + firstToken + i];
          visit(s, a, wid, tokStr);
        }
      }
    }
  }

  AyahReferenceUnits getAyahUnits(int surah, int ayah) {
    RangeError.checkValueInInterval(surah, 1, surahs, 'surah');
    final int totalInSurah = ayahCount(surah);
    RangeError.checkValueInInterval(ayah, 1, totalInSurah, 'ayah');

    final int ayahIndex = _surahFirst[surah - 1] + ayah - 1;
    final int recordOffset = _offAyahIndex + ayahIndex * _ayahRecordSize;

    final int firstToken = _bd.getUint32(recordOffset, Endian.little);
    final int firstMadd = _bd.getUint32(recordOffset + 4, Endian.little);
    final int formsOff = _bd.getUint32(recordOffset + 8, Endian.little);
    final int count = _bd.getUint16(recordOffset + 12, Endian.little);
    final int maddCount = _bd.getUint16(recordOffset + 14, Endian.little);
    final int wordCount = _bytes[recordOffset + 16];

    final units = List<int>.generate(
      count,
      (i) => _bytes[_offTokens + firstToken + i],
      growable: false,
    );
    final wordIndices = List<int>.generate(
      count,
      (i) => _bytes[_offWords + firstToken + i],
      growable: false,
    );
    final tokenFlags = List<int>.generate(
      count,
      (i) => _bd.getUint16(_offFlags + 2 * (firstToken + i), Endian.little),
      growable: false,
    );
    final maddEntries = List<MaddEntry>.generate(
      maddCount,
      (i) {
        final int entryOffset = _offMadd + (firstMadd + i) * 8;
        return MaddEntry(
          tokenIndex: _bd.getUint16(entryOffset, Endian.little),
          ruleClass: _bytes[entryOffset + 2],
          allowedCounts: _bytes[entryOffset + 4],
          canonicalCount: _bytes[entryOffset + 6],
          flags: _bytes[entryOffset + 7],
        );
      },
      growable: false,
    );

    final wordForms = _readWordForms(
      formsOff: formsOff,
      wordCount: wordCount,
      units: units,
      wordIndices: wordIndices,
    );

    return AyahReferenceUnits(
      surah: surah,
      ayah: ayah,
      units: units,
      wordIndices: wordIndices,
      wordCount: wordCount,
      tokenFlags: tokenFlags,
      maddEntries: maddEntries,
      wordForms: wordForms,
    );
  }

  static List<String> _sanitizeWordForms(
    String canonical,
    List<String> rawForms,
  ) {
    if (rawForms.isEmpty) return const [];
    final rawSet = rawForms.toSet();
    final seen = <String>{canonical};
    final out = <String>[];

    for (final fm in rawForms) {
      if (fm.isEmpty || fm == canonical) continue;

      if (canonical.length >= 3 &&
          fm.length == canonical.length - 1 &&
          canonical.startsWith(fm) &&
          PhoneticSymbols.isTanweenNasalChar(
              canonical.codeUnitAt(canonical.length - 1)) &&
          PhoneticSymbols.isVowelChar(
              canonical.codeUnitAt(canonical.length - 2)) &&
          canonical.codeUnitAt(canonical.length - 3) !=
              canonical.codeUnitAt(canonical.length - 2) &&
          rawSet.contains(fm.substring(0, fm.length - 1))) {
        continue;
      }

      if (fm.length + 1 == canonical.length &&
          canonical.startsWith(fm) &&
          PhoneticSymbols.isVowelChar(
              canonical.codeUnitAt(canonical.length - 1)) &&
          (canonical.length < 2 ||
              canonical.codeUnitAt(canonical.length - 2) !=
                  canonical.codeUnitAt(canonical.length - 1))) {
        continue;
      }

      if (seen.add(fm)) {
        out.add(fm);
      }
    }

    return out.isEmpty ? const [] : List<String>.unmodifiable(out);
  }

  List<List<String>> _readWordForms({
    required int formsOff,
    required int wordCount,
    required List<int> units,
    required List<int> wordIndices,
  }) {
    if (formsBytes == 0 || wordCount <= 0) return const [];
    if (_offForms <= 0 || _offForms + formsOff >= _bytes.length) {
      throw const QuranTarteelException(
        QuranTarteelErrorCode.invalidReferenceData,
      );
    }

    final canonicalWords = <String>[];
    if (units.isNotEmpty && wordIndices.length == units.length) {
      final sb = StringBuffer();
      for (int i = 0; i < units.length; i++) {
        final String tok = tokenName(units[i]);
        if (tok != '|') sb.write(tok);
        final bool ended =
            i + 1 == units.length || wordIndices[i + 1] != wordIndices[i];
        if (ended) {
          canonicalWords.add(sb.toString());
          sb.clear();
        }
      }
    }

    int p = _offForms + formsOff;
    final int limit = _bytes.length;
    final result = List<List<String>>.filled(wordCount, const []);

    for (int w = 0; w < wordCount; w++) {
      if (p + 2 > limit) {
        throw const QuranTarteelException(
          QuranTarteelErrorCode.invalidReferenceData,
        );
      }
      p++; // tag byte
      final int nForms = _bytes[p++];
      final rawForms = <String>[];

      for (int f = 0; f < nForms; f++) {
        if (p >= limit) {
          throw const QuranTarteelException(
            QuranTarteelErrorCode.invalidReferenceData,
          );
        }
        final int len = _bytes[p++];
        if (p + len > limit) {
          throw const QuranTarteelException(
            QuranTarteelErrorCode.invalidReferenceData,
          );
        }
        final sb = StringBuffer();
        for (int k = 0; k < len; k++) {
          sb.write(tokenName(_bytes[p + k]));
        }
        rawForms.add(sb.toString());
        p += len;
      }

      if (p >= limit) {
        throw const QuranTarteelException(
          QuranTarteelErrorCode.invalidReferenceData,
        );
      }
      final int nRules = _bytes[p++];
      p += nRules * 4;
      if (p > limit) {
        throw const QuranTarteelException(
          QuranTarteelErrorCode.invalidReferenceData,
        );
      }

      final String canonical =
          w < canonicalWords.length ? canonicalWords[w] : '';
      result[w] = _sanitizeWordForms(canonical, rawForms);
    }

    return result;
  }
}

/// Groups `expected_tj3.zfx` token streams into Uthmani word entries with
/// interned [WordTajweedRule] tables and Muqatta'at structural merges.
class ReferenceComposer {
  /// Number of leading zfx phonetic units forming a single Uthmani Muqatta'at
  /// word at index 0 (packed `(surah << 12) | ayah` -> unit count).
  static const Map<int, int> _muqattaatLeadMerges = {
    (2 << 12) | 1: 3, (3 << 12) | 1: 3, (7 << 12) | 1: 4, (10 << 12) | 1: 3,
    (11 << 12) | 1: 3, (12 << 12) | 1: 3, (13 << 12) | 1: 4, (14 << 12) | 1: 3,
    (15 << 12) | 1: 3, (19 << 12) | 1: 5, (20 << 12) | 1: 2, (26 << 12) | 1: 3,
    (27 << 12) | 1: 2, (28 << 12) | 1: 3, (29 << 12) | 1: 3, (30 << 12) | 1: 3,
    (31 << 12) | 1: 3, (32 << 12) | 1: 3, (36 << 12) | 1: 2, (40 << 12) | 1: 2,
    (41 << 12) | 1: 2, (42 << 12) | 1: 2, (42 << 12) | 2: 3, (43 << 12) | 1: 2,
    (44 << 12) | 1: 2, (45 << 12) | 1: 2, (46 << 12) | 1: 2,
  };

  /// Composes [ref] token sequences into per-word [ComposedWord] descriptors.
  static List<ComposedWord> compose(
    AyahReferenceUnits ref, {
    required TajweedFormerReferenceReader reader,
  }) {
    final int n = ref.units.length;
    if (n == 0 || ref.wordIndices.isEmpty) return const [];

    final Map<int, MaddEntry>? maddMap = ref.maddEntries.isEmpty
        ? null
        : {for (final e in ref.maddEntries) e.tokenIndex: e};
    final List<ComposedWord> words = [];
    final int mergeCount =
        _muqattaatLeadMerges[(ref.surah << 12) | ref.ayah] ?? 1;

    int wordStart = 0;
    int wordIdx = 0;
    for (int i = 1; i <= n; i++) {
      final bool wordEnded =
          i == n || ref.wordIndices[i] != ref.wordIndices[i - 1];
      if (wordEnded) {
        final int currentIdx = wordIdx++;
        if (words.isEmpty && wordIdx < mergeCount && i < n) continue;
        final List<String> forms = (words.isEmpty && mergeCount > 1)
            ? const []
            : (currentIdx < ref.wordForms.length
                ? ref.wordForms[currentIdx]
                : const []);
        words.add(
          _composeWord(
            ref,
            maddMap,
            wordStart,
            i,
            reader: reader,
            alternateForms: forms,
          ),
        );
        wordStart = i;
      }
    }
    return words;
  }

  static ComposedWord _composeWord(
    AyahReferenceUnits ref,
    Map<int, MaddEntry>? maddMap,
    int start,
    int end, {
    required TajweedFormerReferenceReader reader,
    List<String> alternateForms = const [],
  }) {
    final StringBuffer sb = StringBuffer();
    final List<int> charClasses = [];
    final List<WordTajweedRule> rules = [];
    final List<int> ruleOfClass = [];

    for (int i = start; i < end; i++) {
      final String token = reader.tokenName(ref.units[i]);
      if (token == '|') continue;

      final int flags = i < ref.tokenFlags.length ? ref.tokenFlags[i] : 0;
      final MaddEntry? madd = maddMap?[i];
      final int? ruleIndex = _assignRule(flags, madd, rules, ruleOfClass);

      sb.write(token);
      for (int c = 0; c < token.length; c++) {
        charClasses.add(ruleIndex ?? 0);
      }
    }

    return ComposedWord(
      phoneme: sb.toString(),
      charRuleClasses: charClasses,
      rules: rules,
      alternateForms: alternateForms,
    );
  }

  static int? _assignRule(
    int flags,
    MaddEntry? madd,
    List<WordTajweedRule> rules,
    List<int> ruleOfClass,
  ) {
    final int maddFlagClass = madd?.ruleClass ?? ((flags >> 9) & 0x7);
    final int ghunnaExpected = (flags >> 4) & 0x7;
    final bool isQalqalahSite = (flags & (1 << 1)) != 0;
    final int qalqalahExpected = (flags >> 2) & 0x3;
    final bool isGeminate = (flags & (1 << 0)) != 0;

    if (madd != null || maddFlagClass != 0) {
      if (madd == null || madd.canonicalCount <= 0) {
        throw const QuranTarteelException(
          QuranTarteelErrorCode.invalidReferenceData,
        );
      }
      final int klass = madd.ruleClass;
      final int canonical = madd.canonicalCount;
      final int ruleId = _decodeMaddRuleId(
        klass,
        canonical: canonical,
        allowedCounts: madd.allowedCounts,
        ghunnaExpected: ghunnaExpected,
        maddLetterBase: madd.isMaddLetterBase,
      );
      return _intern(
        rules,
        ruleOfClass,
        ruleId,
        canonical,
        klass,
        ghunnaExpected: ruleId == 10 ? ghunnaExpected : 0,
        allowedCounts: madd.allowedCounts,
      );
    }

    if (ghunnaExpected > 1) {
      return _intern(
        rules,
        ruleOfClass,
        10,
        2,
        0,
        ghunnaExpected: ghunnaExpected,
      );
    }

    final bool hasQalqalah = isQalqalahSite && qalqalahExpected > 0;

    if (isGeminate) {
      return _intern(
        rules,
        ruleOfClass,
        9,
        1,
        0,
        hasQalqalah: hasQalqalah,
        qalqalahExpected: hasQalqalah ? qalqalahExpected : 0,
      );
    }

    if (hasQalqalah) {
      return _intern(
        rules,
        ruleOfClass,
        8,
        1,
        qalqalahExpected,
        hasQalqalah: true,
        qalqalahExpected: qalqalahExpected,
      );
    }

    return null;
  }

  static int _decodeMaddRuleId(
    int klass, {
    required int canonical,
    required int allowedCounts,
    required int ghunnaExpected,
    required bool maddLetterBase,
  }) {
    switch (klass) {
      case 1:
        return 1;
      case 2:
        return (allowedCounts & (1 << 6)) != 0 ? 4 : 3;
      case 3:
        return (allowedCounts & (1 << 2)) != 0 ? 5 : 2;
      case 4:
        return canonical >= 6 ? 6 : 1;
      case 5:
        if (ghunnaExpected > 1 && !maddLetterBase) return 10;
        return canonical >= 6 ? 6 : 7;
      default:
        throw const QuranTarteelException(
          QuranTarteelErrorCode.invalidReferenceData,
        );
    }
  }

  static int _intern(
    List<WordTajweedRule> rules,
    List<int> ruleOfClass,
    int ruleId,
    int goldenLen,
    int zfxClass, {
    bool hasQalqalah = false,
    int ghunnaExpected = 0,
    int qalqalahExpected = 0,
    int allowedCounts = 0,
  }) {
    for (int i = 0; i < rules.length; i++) {
      final r = rules[i];
      if (r.ruleId == ruleId &&
          r.goldenLen == goldenLen &&
          r.hasQalqalah == hasQalqalah &&
          r.ghunnaExpected == ghunnaExpected &&
          r.qalqalahExpected == qalqalahExpected &&
          r.allowedCounts == allowedCounts &&
          (zfxClass == 0 || ruleOfClass[i] == zfxClass)) {
        return i + 1;
      }
    }
    rules.add(
      WordTajweedRule(
        ruleId: ruleId,
        goldenLen: goldenLen,
        hasQalqalah: hasQalqalah,
        ghunnaExpected: ghunnaExpected,
        qalqalahExpected: qalqalahExpected,
        allowedCounts: allowedCounts,
      ),
    );
    ruleOfClass.add(zfxClass);
    return rules.length;
  }
}
