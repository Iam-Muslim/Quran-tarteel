import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_tarteel/scoring.dart';

const PhonemeVocabulary _testVocab = PhonemeVocabulary(
  names: ['<blk>', '|', 'ب', 'س', 'م', 'ل', 'ه', 'a', 'i', 'u'],
  blank: 0,
  wordBar: 1,
);

/// Builds a minimal valid ZFTJEXP1 binary table with 1 surah, 2 ayahs:
/// Ayah 1: word 0 = "بiسm" (with Madd rule on 'a' in word 1) -> actually let's make:
/// Ayah 1: word 0 = "بiس", word 1 = "مaa" (Madd ruleId=1 on 'aa')
/// Ayah 2: word 0 = "لaهu"
Uint8List _buildSyntheticZfx() {
  // Tokens for Ayah 1: ب(2) i(8) س(3) |(1) م(4) a(7) a(7)  -> 7 tokens, 2 words
  // Tokens for Ayah 2: ل(5) a(7) ه(6) u(9)                -> 4 tokens, 1 word
  final tokens = <int>[2, 8, 3, 1, 4, 7, 7, 5, 7, 6, 9];
  final words = <int>[0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0];
  // Set Madd class 1 (bits 9..11 = 1) on indices 5,6 ('a','a') in ayah 1
  final flags = <int>[0, 0, 0, 0, 0, 1 << 9, 1 << 9, 0, 0, 0, 0];

  // 2 madd entries for ayah 1 (tokenIndex 5 & 6 local to ayah 1)
  final maddEntries = <List<int>>[
    [5, 1, 0, 1 << 1, 0, 2, 1],
    [6, 1, 0, 1 << 1, 0, 2, 1],
  ];

  const int headerSize = 160;
  const int offAyahCounts = headerSize; // 1 surah * 2 = 2 bytes -> align to 4
  const int offAyahIndex = offAyahCounts + 4; // 2 ayahs * 20 = 40
  final int offTokens = offAyahIndex + 40;
  final int offWords = offTokens + tokens.length;
  final int offFlags = (offWords + words.length + 1) & ~1;
  final int offMadd = offFlags + flags.length * 2;
  final int fileSize = offMadd + maddEntries.length * 8;

  final bytes = Uint8List(fileSize);
  final bd = ByteData.sublistView(bytes);

  const magic = [0x5A, 0x46, 0x54, 0x4A, 0x45, 0x58, 0x50, 0x31];
  for (int i = 0; i < 8; i++) {
    bytes[i] = magic[i];
  }
  bd.setUint32(8, 1, Endian.little); // version
  bd.setUint32(12, headerSize, Endian.little);
  bd.setUint32(16, fileSize, Endian.little);
  bd.setUint32(20, 1, Endian.little); // surahs
  bd.setUint32(24, 2, Endian.little); // totalAyahs
  bd.setUint32(28, tokens.length, Endian.little);
  bd.setUint32(32, maddEntries.length, Endian.little);
  bd.setUint32(36, 0, Endian.little); // formsBytes

  bd.setUint32(104, offAyahCounts, Endian.little);
  bd.setUint32(108, offAyahIndex, Endian.little);
  bd.setUint32(112, offTokens, Endian.little);
  bd.setUint32(116, offWords, Endian.little);
  bd.setUint32(120, offFlags, Endian.little);
  bd.setUint32(124, offMadd, Endian.little);
  bd.setUint32(128, fileSize, Endian.little);

  bd.setUint16(offAyahCounts, 2, Endian.little);

  // Ayah 1 record
  bd.setUint32(offAyahIndex, 0, Endian.little); // firstToken
  bd.setUint32(offAyahIndex + 4, 0, Endian.little); // firstMadd
  bd.setUint32(offAyahIndex + 8, 0, Endian.little); // formsOff
  bd.setUint16(offAyahIndex + 12, 7, Endian.little); // tokCount
  bd.setUint16(offAyahIndex + 14, 2, Endian.little); // maddCount
  bytes[offAyahIndex + 16] = 2; // wordCount

  // Ayah 2 record
  bd.setUint32(offAyahIndex + 20, 7, Endian.little);
  bd.setUint32(offAyahIndex + 24, 2, Endian.little);
  bd.setUint32(offAyahIndex + 28, 0, Endian.little);
  bd.setUint16(offAyahIndex + 32, 4, Endian.little);
  bd.setUint16(offAyahIndex + 34, 0, Endian.little);
  bytes[offAyahIndex + 36] = 1;

  for (int i = 0; i < tokens.length; i++) {
    bytes[offTokens + i] = tokens[i];
    bytes[offWords + i] = words[i];
    bd.setUint16(offFlags + i * 2, flags[i], Endian.little);
  }
  for (int i = 0; i < maddEntries.length; i++) {
    final e = maddEntries[i];
    final off = offMadd + i * 8;
    bd.setUint16(off, e[0], Endian.little);
    bytes[off + 2] = e[1];
    bytes[off + 3] = e[2];
    bytes[off + 4] = e[3];
    bytes[off + 5] = e[4];
    bytes[off + 6] = e[5];
    bytes[off + 7] = e[6];
  }

  return bytes;
}

void main() {
  group('QuranRepository & ZFX strict loading', () {
    test('rejects corrupted ZFX bytes with QuranTarteelException', () {
      expect(
        () => QuranRepository.fromZfxBytes(
          Uint8List.fromList([1, 2, 3, 4]),
          vocabulary: _testVocab,
        ),
        throwsA(isA<QuranTarteelException>()),
      );
    });

    test('throws uninitialized before load and RangeError on invalid coords', () {
      final emptyRepo = QuranRepository();
      expect(
        () => emptyRepo.getSurah(1),
        throwsA(isA<QuranTarteelException>()),
      );

      final repo = QuranRepository.fromZfxBytes(
        _buildSyntheticZfx(),
        vocabulary: _testVocab,
      );
      expect(repo.surahCount, 1);
      expect(() => repo.getSurah(2), throwsRangeError);
      expect(() => repo.getVerse(1, 3), throwsRangeError);
      expect(() => repo.getWordGlobalIndex(1, 1, 5), throwsRangeError);

      final ayah1 = repo.getVerse(1, 1);
      expect(ayah1.phonemeWords, ['بiس', 'مaa']);
      expect(ayah1.wordRules[1].single.ruleId, 1);
    });

    test('rejects duplicate unforced loadBytes and mismatched tokensSha256', () {
      final bytes = _buildSyntheticZfx();
      final repo = QuranRepository.fromZfxBytes(bytes, vocabulary: _testVocab);

      expect(
        () => repo.loadBytes(bytes, vocabulary: _testVocab),
        throwsStateError,
      );

      // Zeroed header digest in synthetic table matches 64 zeros and rejects mismatch.
      expect(
        () => repo.loadBytes(
          bytes,
          vocabulary: _testVocab,
          expectedTokensSha256: '0' * 64,
          forceReload: true,
        ),
        returnsNormally,
      );

      expect(
        () => repo.loadBytes(
          bytes,
          vocabulary: _testVocab,
          expectedTokensSha256: 'a' * 64,
          forceReload: true,
        ),
        throwsA(
          isA<QuranTarteelException>().having(
            (e) => e.code,
            'code',
            QuranTarteelErrorCode.invalidReferenceData,
          ),
        ),
      );
    });
  });

  group('QuranScorer alignment & Tajweed frontier shield', () {
    test('commits words and evaluates Madd holding across frontier', () async {
      final repo = QuranRepository.fromZfxBytes(
        _buildSyntheticZfx(),
        vocabulary: _testVocab,
      );
      final scorer = QuranScorer(
        repository: repo,
        config: const TrackerConfig(
          tajweed: TajweedConfig(qalqalahTau: 0.5),
        ),
        isTajweed: true,
      );

      expect(
        () => scorer.setTargetSurah(1),
        throwsA(isA<QuranTarteelException>()),
      );

      await scorer.initialize();
      scorer.setTargetSurah(1);

      final events = <WordMatchedEvent>[];
      final sub = scorer.onWordEvaluated.listen(events.add);

      // Feed word 0 ("بiس") + word 1 ("مaa") still held at frontier (not final yet)
      scorer.feedTranscript(
        const TranscriptionResult(
          text: 'بiس مaa',
          isFinal: false,
          tokens: ['ب', 'i', 'س', '|', 'م', 'a', 'a'],
          timestamps: [0.10, 0.16, 0.24, 0.28, 0.36, 0.42, 0.48],
          durations: [0.06, 0.04, 0.06, 0.02, 0.06, 0.04, 0.04],
          streamEpoch: 1,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 80));
      // Word 0 commits immediately; word 1 ("مaa") is held by HeldFrontierShield!
      expect(events.length, 1);
      expect(events[0].wordInAyah, 0);
      expect(events[0].verdict, WordEvaluationVerdict.correct);

      // Now next word onset arrives after holding Madd for 0.30s -> shield lifts!
      scorer.feedTranscript(
        const TranscriptionResult(
          text: 'بiس مaa لaهu',
          isFinal: true,
          tokens: ['ب', 'i', 'س', '|', 'م', 'a', 'a', '|', 'ل', 'a', 'ه', 'u'],
          timestamps: [
            0.10, 0.16, 0.24, 0.28, 0.36, 0.42, 0.48, 0.72, 0.80, 0.86, 0.94, 1.00,
          ],
          durations: [
            0.06, 0.04, 0.06, 0.02, 0.06, 0.04, 0.04, 0.02, 0.06, 0.04, 0.06, 0.04,
          ],
          streamEpoch: 1,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(events.length, 3);
      expect(events[1].ayah, 1);
      expect(events[1].wordInAyah, 1);
      expect(events[1].verdict, WordEvaluationVerdict.correct);
      expect(events[2].ayah, 2);
      expect(events[2].wordInAyah, 0);

      await sub.cancel();
      scorer.dispose();
    });

    test('throws disposed on lifecycle mutators after dispose()', () async {
      final repo = QuranRepository.fromZfxBytes(
        _buildSyntheticZfx(),
        vocabulary: _testVocab,
      );
      final scorer = QuranScorer(repository: repo);
      await scorer.initialize();
      scorer.dispose();
      // dispose() itself remains idempotent.
      scorer.dispose();

      Matcher throwsDisposed() => throwsA(
            isA<QuranTarteelException>().having(
              (e) => e.code,
              'code',
              QuranTarteelErrorCode.disposed,
            ),
          );

      expect(() => scorer.resetBuffer(), throwsDisposed());
      expect(() => scorer.setTajweedMode(false), throwsDisposed());
      expect(() => scorer.updateConfig(const TrackerConfig()), throwsDisposed());
      expect(
        () => scorer.updateTajweedConfig(const TajweedConfig()),
        throwsDisposed(),
      );
      expect(() => scorer.setTargetSurah(1), throwsDisposed());
      expect(
        () => scorer.feedTranscript(const TranscriptionResult(text: 'بiس')),
        throwsDisposed(),
      );
    });
  });
}
