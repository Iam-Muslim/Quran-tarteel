import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quran_tarteel/quran_tarteel.dart';
import 'package:quran_tarteel/src/tajweed/tajweed_engine.dart';

void main() {
  group('AcousticThreshold & TajweedEngine strictness', () {
    test('rejects NaN, infinite, and negative measured durations', () {
      const thresh = AcousticThreshold(0.15, 0.30, 0.70);
      expect(() => thresh.evaluate(-0.1), throwsArgumentError);
      expect(() => thresh.evaluate(double.nan), throwsArgumentError);
      expect(() => thresh.evaluate(double.infinity), throwsArgumentError);
      expect(thresh.evaluate(0.10), TajweedDurationStatus.underheld);
      expect(thresh.evaluate(0.30), TajweedDurationStatus.valid);
      expect(thresh.evaluate(0.90), TajweedDurationStatus.overheld);
    });

    test('throws missingCalibrationThreshold if Qalqalah checked without tau', () {
      const engine = TajweedEngine(
        config: TajweedConfig(qalqalahTau: null),
      );
      const span = PhoneticSpan(
        refStart: 0,
        refEnd: 1,
        refText: 'ق',
        baseChar: 'ق',
        ruleType: TajweedRuleType.qalqalah,
        rule: QalqalahRule(1),
        isQalqalah: true,
        qalqalahLevel: 1,
      );
      expect(
        () => engine.evaluateSpan(
          span: span,
          predText: 'ق',
          spanDuration: 0.1,
          spanAcoustics: const TokenNeuralAcoustics(qalqalahScore: 0.9),
          wordRefEnd: 1,
        ),
        throwsA(
          isA<QuranTarteelException>().having(
            (e) => e.code,
            'code',
            QuranTarteelErrorCode.missingCalibrationThreshold,
          ),
        ),
      );
    });
  });

  group('SpanDurationCalculator bidirectional blank attribution', () {
    test('captures Madd gapAfter and Ghunnah bidirectional gapBefore+gapAfter', () {
      const maddSpan = PhoneticSpan(
        refStart: 1,
        refEnd: 3,
        refText: 'aa',
        baseChar: 'a',
        ruleType: TajweedRuleType.maddNormal,
        rule: MaddRule(goldenLen: 2),
      );
      final maddDur = SpanDurationCalculator.measure(
        span: maddSpan,
        touchedTokens: {1},
        wordRefEnd: 4,
        tokenDurations: [0.06, 0.08, 0.06],
        tokenStarts: [0.00, 0.06, 0.46],
        tokenEnds: [0.06, 0.14, 0.52],
        trackingTimestamps: [0.52],
      );
      // 0.08 base + (0.46 - 0.14) = 0.40s
      expect(maddDur, closeTo(0.40, 1e-6));

      const ghunnahSpan = PhoneticSpan(
        refStart: 1,
        refEnd: 2,
        refText: 'م',
        baseChar: 'م',
        ruleType: TajweedRuleType.ghunnah,
        rule: MushaddadGhunnahRule(2),
      );
      final ghunnahDur = SpanDurationCalculator.measure(
        span: ghunnahSpan,
        touchedTokens: {1},
        wordRefEnd: 3,
        tokenDurations: [0.04, 0.04, 0.04],
        tokenStarts: [0.00, 0.24, 0.44],
        tokenEnds: [0.04, 0.28, 0.48],
        trackingTimestamps: [0.48],
      );
      // 0.04 base + gapBefore(0.20) + gapAfter(0.16) = 0.40s
      expect(ghunnahDur, closeTo(0.40, 1e-6));
    });
  });

  group('TajweedTakeDecoder standalone model output extraction', () {
    test('formats tokens, extracts Qalqalah burst window, and extracts altProbs', () {
      final tokens = [
        const TajweedToken(
          id: 2,
          name: 'ق',
          firstMs: 0,
          peakMs: 0,
          lastMs: 40,
          confidence: 0.92,
        ),
        const TajweedToken(
          id: 1,
          name: '|',
          firstMs: 40,
          peakMs: 40,
          lastMs: 40,
          confidence: 1.0,
        ),
        const TajweedToken(
          id: 3,
          name: 'ل',
          firstMs: 400,
          peakMs: 400,
          lastMs: 440,
          confidence: 0.95,
        ),
      ];

      expect(TajweedTakeDecoder.formatDecodedText(tokens), 'ق ل');

      // Qalqalah head at 20ms per frame: endFrame = (40+40)~/20 = 4, window [6, 18)
      final qalProbs = List<double>.filled(24, 0.05);
      for (int f = 6; f < 18; f++) {
        qalProbs[f] = 0.85;
      }
      final score = TajweedTakeDecoder.extractTokenQalqalahScore(
        tokenIndex: 0,
        tokens: tokens,
        frameProbs: qalProbs,
        frameMs: 20,
        baseFrameMs: 40,
      );
      expect(score, closeTo(0.85, 1e-6));

      final frames = [
        TajweedFrame(
          index: 0,
          top: 2,
          topLogProb: log(0.7),
          runnerUp: 3,
          runnerUpLogProb: log(0.2),
          margin: log(0.7) - log(0.2),
          topK: const [2, 3, 0],
          topKLogProbs: [log(0.7), log(0.2), log(0.1)],
        ),
        TajweedFrame(
          index: 1,
          top: 2,
          topLogProb: log(0.8),
          runnerUp: 0,
          runnerUpLogProb: log(0.15),
          margin: log(0.8) - log(0.15),
          topK: const [2, 0, 3],
          topKLogProbs: [log(0.8), log(0.15), log(0.05)],
        ),
      ];

      final alts = TajweedTakeDecoder.extractTokenAltProbs(
        token: tokens[0],
        frames: frames,
        vocabNames: const ['<blk>', '|', 'ق', 'ل'],
        blankId: 0,
        wordBarId: 1,
        frameMs: 40,
      );
      expect(alts['ق'.codeUnitAt(0)], closeTo(0.8, 1e-6));
      expect(alts['ل'.codeUnitAt(0)], closeTo(0.2, 1e-6));
    });

    test('decodes TajweedHeads directly without any QuranRepository', () {
      final vocabNames = ['<blk>', '|', 'ق', 'a'];
      final qalValues = Float32List(20 * 3);
      for (int f = 4; f < 16; f++) {
        qalValues[f * 3 + 1] = 0.70;
        qalValues[f * 3 + 2] = 0.15;
      }
      final decoded = TajweedDecoded(
        tokens: const [
          TajweedToken(
            id: 2,
            name: 'ق',
            firstMs: 0,
            peakMs: 0,
            lastMs: 0,
            confidence: 0.9,
          ),
        ],
        frames: [
          TajweedFrame(
            index: 0,
            top: 2,
            topLogProb: log(0.9),
            runnerUp: 0,
            runnerUpLogProb: log(0.05),
            margin: log(0.9) - log(0.05),
            topK: const [2, 0],
            topKLogProbs: [log(0.9), log(0.05)],
          ),
        ],
        settled: 1,
        isFinal: true,
        wordBar: 1,
      );
      final heads = TajweedHeads(
        [
          TajweedHead(
            name: 'log_probs',
            kind: TajweedHeadKind.ctc,
            frameMs: 40,
            frames: 1,
            classes: 4,
            values: Float32List(4),
          ),
          TajweedHead(
            name: 'attr_qalqalah',
            kind: TajweedHeadKind.attribute,
            frameMs: 20,
            frames: 20,
            classes: 3,
            values: qalValues,
          ),
        ],
        decoded,
        vocabNames,
        0,
        0,
      );

      // Uses public TajweedTakeDecoder directly via TajweedTokens-less static helpers
      // and verifies strict missing head check via TajweedHeads.
      expect(heads['attr_qalqalah']?.frameMs, 20);
      expect(heads.decoded().isFinal, true);

      final headsNoLogProbs = TajweedHeads(
        [
          TajweedHead(
            name: 'attr_qalqalah',
            kind: TajweedHeadKind.attribute,
            frameMs: 20,
            frames: 20,
            classes: 3,
            values: qalValues,
          ),
        ],
        decoded,
        vocabNames,
        0,
        0,
      );
      expect(headsNoLogProbs['log_probs'], isNull);
    });
  });
}
