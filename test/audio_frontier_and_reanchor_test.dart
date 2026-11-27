import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_tarteel/quran_tarteel.dart';
import 'package:quran_tarteel/src/dictation/auto_reanchor.dart';
import 'package:quran_tarteel/src/dictation/sequencer.dart';
import 'package:quran_tarteel/src/dictation/worker.dart';
import 'package:quran_tarteel/src/tajweed/tajweed_engine.dart';

void main() {
  group('Pcm16StreamNormalizer', () {
    test('carries trailing odd byte across packets and normalizes Int16LE', () {
      final normalizer = Pcm16StreamNormalizer();

      // Single byte -> held in carry buffer, nothing emitted yet.
      expect(normalizer.push(Uint8List.fromList([0x00])), isNull);

      // Completes first sample 0x8000 (-32768 -> -1.0), plus trailing 0xFF.
      final first = normalizer.push(Uint8List.fromList([0x80, 0xFF]));
      expect(first, isNotNull);
      expect(first!.length, 1);
      expect(first[0], closeTo(-1.0, 1e-6));

      // Completes second sample 0x7FFF (+32767 -> 32767 / 32768.0).
      final second = normalizer.push(Uint8List.fromList([0x7F]));
      expect(second, isNotNull);
      expect(second!.length, 1);
      expect(second[0], closeTo(32767 / 32768.0, 1e-6));

      // Trailing odd byte followed by reset() discards carry cleanly.
      expect(normalizer.push(Uint8List.fromList([0x12])), isNull);
      normalizer.reset();
      expect(normalizer.push(Uint8List.fromList([0x00, 0x00]))![0], 0.0);
    });
  });

  group('HeldFrontierShield & AutoReanchorFinder', () {
    test('holds word ending with Madd at live frontier and releases next word', () {
      const refPhonemes = 'مaa';
      final trace = [
        const PhonemeGroupAlignment(
            opType: AlignmentOp.match, refIdx: 0, predIdx: 0),
        const PhonemeGroupAlignment(
            opType: AlignmentOp.match, refIdx: 1, predIdx: 1),
        const PhonemeGroupAlignment(
            opType: AlignmentOp.match, refIdx: 2, predIdx: 2),
      ];
      const rules = [WordTajweedRule(ruleId: 1, goldenLen: 2)];
      const charClasses = [0, 1, 1];

      final held = HeldFrontierShield.shouldHold(
        trace: trace,
        refPhonemes: refPhonemes,
        refEnd: refPhonemes.length,
        charRuleClasses: charClasses,
        wordRules: rules,
        tajweedConfig: const TajweedConfig(),
        asrCharAnchor: 0,
        segmentTimestamps: const [0.10, 0.14, 0.18],
        segmentCharTokenIndices: const [0, 1, 2],
        segmentTokenStarts: const [0.06, 0.10, 0.14],
        segmentTokenEnds: const [0.10, 0.14, 0.18],
        checkFrontier: true,
      );
      expect(held, isTrue);

      final released = HeldFrontierShield.shouldHold(
        trace: trace,
        refPhonemes: refPhonemes,
        refEnd: refPhonemes.length,
        charRuleClasses: charClasses,
        wordRules: rules,
        tajweedConfig: const TajweedConfig(),
        asrCharAnchor: 0,
        segmentTimestamps: const [0.10, 0.14, 0.18],
        segmentCharTokenIndices: const [0, 1, 2],
        segmentTokenStarts: const [0.06, 0.10, 0.14],
        segmentTokenEnds: const [0.10, 0.14, 0.18],
        checkFrontier: false,
      );
      expect(released, isFalse);
    });

    test('AutoReanchorFinder recovers unique forward jump and blocks Mutashabihat', () {
      final words = ['أaو', 'بiس', 'مaa', 'لaهu', 'قuل', 'هuوaلaهuأaحaد'];
      final full = words.join('');
      final boundaries = <int>[0];
      for (final w in words) {
        boundaries.add(boundaries.last + w.length);
      }

      const config = TrackerConfig(
        enableAutoReanchor: true,
        reanchorStallThreshold: 8,
      );

      final uniqueHit = AutoReanchorFinder.findForwardReanchor(
        rawQuery: 'قuلهuوaلaهuأaحaد',
        fullPhonemes: full,
        wordBoundaries: boundaries,
        wordCount: words.length,
        targetWordCursor: 0,
        config: config,
      );
      expect(uniqueHit, isNotNull);
      expect(uniqueHit!.wordIndex, 4);

      // Duplicated verse passage -> Mutashabihat guard returns null!
      final duplicatedWords = [
        'أaو',
        'قuلأaعuوذu',
        'مaa',
        'تiن',
        'فiق',
        'قuلأaعuوذu',
      ];
      final dupFull = duplicatedWords.join('');
      final dupBoundaries = <int>[0];
      for (final w in duplicatedWords) {
        dupBoundaries.add(dupBoundaries.last + w.length);
      }

      final ambiguousHit = AutoReanchorFinder.findForwardReanchor(
        rawQuery: 'قuلأaعuوذu',
        fullPhonemes: dupFull,
        wordBoundaries: dupBoundaries,
        wordCount: duplicatedWords.length,
        targetWordCursor: 0,
        config: config,
      );
      expect(ambiguousHit, isNull);
    });
  });

  group('DictationSequencer strict reference validation', () {
    test('throws ArgumentError when charRuleClasses is shorter than fullPhonemes', () {
      final seq = DictationSequencer((_) {});
      expect(
        () => seq.setSurahReference(
          const SetSurahReferenceCommand(
            fullPhonemes: 'بiس',
            boundaries: [0, 3],
            surahNumber: 1,
            charRuleClasses: [0, 1], // missing 3rd char class
          ),
        ),
        throwsArgumentError,
      );
    });
  });
}
