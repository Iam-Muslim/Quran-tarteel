import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_tarteel/scoring.dart';

const PhonemeVocabulary _searchVocab = PhonemeVocabulary(
  names: ['<blk>', '|', 'ب', 'س', 'م', 'ل', 'ه', 'ح', 'د', 'a', 'i', 'u'],
  blank: 0,
  wordBar: 1,
);

Uint8List _buildSearchZfx() {
  // Ayah 1: بiسmلaaه (7 tokens)
  // Ayah 2: لaهuحaد (7 tokens)
  final tokens = <int>[2, 10, 3, 4, 5, 9, 6, 5, 9, 6, 11, 7, 9, 8];
  final words = <int>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

  const int headerSize = 160;
  const int offAyahCounts = headerSize;
  const int offAyahIndex = offAyahCounts + 4;
  final int offTokens = offAyahIndex + 40;
  final int offWords = offTokens + tokens.length;
  final int offFlags = (offWords + words.length + 1) & ~1;
  final int fileSize = offFlags + tokens.length * 2;

  final bytes = Uint8List(fileSize);
  final bd = ByteData.sublistView(bytes);
  const magic = [0x5A, 0x46, 0x54, 0x4A, 0x45, 0x58, 0x50, 0x31];
  for (int i = 0; i < 8; i++) {
    bytes[i] = magic[i];
  }
  bd.setUint32(8, 1, Endian.little);
  bd.setUint32(12, headerSize, Endian.little);
  bd.setUint32(16, fileSize, Endian.little);
  bd.setUint32(20, 1, Endian.little);
  bd.setUint32(24, 2, Endian.little);
  bd.setUint32(28, tokens.length, Endian.little);
  bd.setUint32(32, 0, Endian.little);
  bd.setUint32(36, 0, Endian.little);

  bd.setUint32(104, offAyahCounts, Endian.little);
  bd.setUint32(108, offAyahIndex, Endian.little);
  bd.setUint32(112, offTokens, Endian.little);
  bd.setUint32(116, offWords, Endian.little);
  bd.setUint32(120, offFlags, Endian.little);
  bd.setUint32(124, fileSize, Endian.little);
  bd.setUint32(128, fileSize, Endian.little);

  bd.setUint16(offAyahCounts, 2, Endian.little);

  bd.setUint32(offAyahIndex, 0, Endian.little);
  bd.setUint16(offAyahIndex + 12, 7, Endian.little);
  bytes[offAyahIndex + 16] = 1;

  bd.setUint32(offAyahIndex + 20, 7, Endian.little);
  bd.setUint16(offAyahIndex + 32, 7, Endian.little);
  bytes[offAyahIndex + 36] = 1;

  for (int i = 0; i < tokens.length; i++) {
    bytes[offTokens + i] = tokens[i];
    bytes[offWords + i] = words[i];
  }
  return bytes;
}

void main() {
  group('VoiceSearchController', () {
    test('throws uninitialized when repository is not loaded', () async {
      final controller = VoiceSearchController(repository: QuranRepository());
      await expectLater(
        controller.preloadIndex(),
        throwsA(isA<QuranTarteelException>()),
      );
      controller.dispose();
    });

    test('matches exact ayah and respects caller-supplied ignorePrefixes', () async {
      final repo = QuranRepository.fromZfxBytes(
        _buildSearchZfx(),
        vocabulary: _searchVocab,
      );
      final controller = VoiceSearchController(
        repository: repo,
        ignorePrefixes: const ['بiسmلaه'],
      );
      await controller.preloadIndex();

      final res = await controller.stopSearch('لaهuحaد');
      expect(res, isNotNull);
      expect(res!.topMatch?.surah, 1);
      expect(res.topMatch?.ayah, 2);
      expect(res.isUnique, isTrue);

      controller.dispose();
    });

    test('honors caller errorRatio directly when opt-in heuristics are off', () async {
      final repo = QuranRepository.fromZfxBytes(
        _buildSearchZfx(),
        vocabulary: _searchVocab,
      );
      final strictController = VoiceSearchController(repository: repo);
      await strictController.preloadIndex();

      // Ayah 2 is 'لaهuحaد' (7 chars in _searchVocab); 'لaهiحiد' has 2 substitutions.
      // With strict errorRatio: 0.0 it must NOT match; with errorRatio: 0.35 (maxEdits=2) it matches.
      final miss = await strictController.stopSearch('لaهiحiد', errorRatio: 0.0);
      expect(miss, isNull);

      final hit = await strictController.stopSearch('لaهiحiد', errorRatio: 0.35);
      expect(hit, isNotNull);
      expect(hit!.topMatch?.ayah, 2);

      strictController.dispose();
    });
  });
}
