// lib/src/tajweed/tajweed_types.dart
// Canonical Tajweed rules, duration thresholds, factory, and typed diagnostic models.

import '../config.dart';
import '../reference/zfx_loader.dart';

/// Canonical Tajweed rule classification matching expected_tj3.zfx taxonomy.
enum TajweedRuleType {
  maddNormal(1),
  maddMonfasel(2),
  maddMottasel(3),
  maddMottaselPause(4),
  maddAared(5),
  maddLazem(6),
  maddLeen(7),
  qalqalah(8),
  shaddah(9),
  ghunnah(10),
  plainLetter(11),
  other(0);

  final int ruleId;
  const TajweedRuleType(this.ruleId);

  bool get isMadd => ruleId >= 1 && ruleId <= 7;

  static TajweedRuleType fromId(int id) {
    for (final t in values) {
      if (t.ruleId == id) return t;
    }
    return other;
  }
}

enum TajweedDurationStatus { valid, underheld, overheld }

class AcousticThreshold {
  final double minSeconds;
  final double targetSeconds;
  final double maxSeconds;

  const AcousticThreshold(this.minSeconds, this.targetSeconds, this.maxSeconds);

  TajweedDurationStatus evaluate(double measuredSeconds) {
    if (measuredSeconds < 0.0 ||
        measuredSeconds.isNaN ||
        measuredSeconds.isInfinite) {
      throw ArgumentError.value(
        measuredSeconds,
        'measuredSeconds',
        'Duration must be finite and >= 0.',
      );
    }
    if (measuredSeconds < minSeconds) return TajweedDurationStatus.underheld;
    if (measuredSeconds > maxSeconds) return TajweedDurationStatus.overheld;
    return TajweedDurationStatus.valid;
  }
}

const Map<RecitationSpeed, AcousticThreshold> _waqfVariableMaddThresholds = {
  RecitationSpeed.fast: AcousticThreshold(0.120, 0.240, 1.800),
  RecitationSpeed.normal: AcousticThreshold(0.300, 0.600, 2.200),
  RecitationSpeed.slow: AcousticThreshold(0.500, 1.080, 2.500),
};

const Map<TajweedRuleType, Map<RecitationSpeed, AcousticThreshold>>
    _ruleThresholdTable = {
  TajweedRuleType.maddNormal: {
    RecitationSpeed.fast: AcousticThreshold(0.075, 0.240, 0.600),
    RecitationSpeed.normal: AcousticThreshold(0.150, 0.300, 0.700),
    RecitationSpeed.slow: AcousticThreshold(0.180, 0.360, 0.850),
  },
  TajweedRuleType.maddMonfasel: {
    RecitationSpeed.fast: AcousticThreshold(0.180, 0.240, 0.800),
    RecitationSpeed.normal: AcousticThreshold(0.450, 0.600, 1.400),
    RecitationSpeed.slow: AcousticThreshold(0.650, 0.900, 1.800),
  },
  TajweedRuleType.maddMottasel: {
    RecitationSpeed.fast: AcousticThreshold(0.350, 0.480, 1.200),
    RecitationSpeed.normal: AcousticThreshold(0.450, 0.600, 1.500),
    RecitationSpeed.slow: AcousticThreshold(0.650, 0.900, 1.800),
  },
  TajweedRuleType.maddMottaselPause: {
    RecitationSpeed.fast: AcousticThreshold(0.350, 0.480, 1.800),
    RecitationSpeed.normal: AcousticThreshold(0.450, 0.600, 2.000),
    RecitationSpeed.slow: AcousticThreshold(0.800, 1.080, 2.500),
  },
  TajweedRuleType.maddAared: _waqfVariableMaddThresholds,
  TajweedRuleType.maddLeen: _waqfVariableMaddThresholds,
  TajweedRuleType.maddLazem: {
    RecitationSpeed.fast: AcousticThreshold(0.540, 0.720, 4.000),
    RecitationSpeed.normal: AcousticThreshold(0.680, 0.900, 4.000),
    RecitationSpeed.slow: AcousticThreshold(0.850, 1.080, 4.500),
  },
  TajweedRuleType.ghunnah: {
    RecitationSpeed.fast: AcousticThreshold(0.180, 0.240, 0.850),
    RecitationSpeed.normal: AcousticThreshold(0.225, 0.300, 0.850),
    RecitationSpeed.slow: AcousticThreshold(0.270, 0.360, 1.600),
  },
  TajweedRuleType.shaddah: {
    RecitationSpeed.fast: AcousticThreshold(0.140, 0.200, 0.650),
    RecitationSpeed.normal: AcousticThreshold(0.160, 0.220, 0.850),
    RecitationSpeed.slow: AcousticThreshold(0.190, 0.260, 1.000),
  },
  TajweedRuleType.plainLetter: {
    RecitationSpeed.fast: AcousticThreshold(0.0, 0.080, 0.350),
    RecitationSpeed.normal: AcousticThreshold(0.0, 0.120, 0.450),
    RecitationSpeed.slow: AcousticThreshold(0.0, 0.160, 0.600),
  },
};

const AcousticThreshold _qalqalahThreshold =
    AcousticThreshold(0.040, 0.120, 0.350);

abstract class TajweedRule {
  final TajweedRuleType ruleType;
  final int ruleId;
  final num goldenLen;

  const TajweedRule({
    required this.ruleType,
    required this.ruleId,
    required this.goldenLen,
  });

  AcousticThreshold getThreshold(RecitationSpeed speed) {
    if (ruleType == TajweedRuleType.qalqalah) return _qalqalahThreshold;
    final bySpeed = _ruleThresholdTable[ruleType];
    if (bySpeed == null) {
      throw StateError('ruleType=$ruleType ruleId=$ruleId');
    }
    return bySpeed[speed]!;
  }

  TajweedDurationStatus checkDurationStatus(
    double durationSeconds, [
    RecitationSpeed speed = RecitationSpeed.normal,
  ]) =>
      getThreshold(speed).evaluate(durationSeconds);

  bool checkDuration(
    double durationSeconds, [
    RecitationSpeed speed = RecitationSpeed.normal,
  ]) =>
      checkDurationStatus(durationSeconds, speed) == TajweedDurationStatus.valid;

  double getRequiredDuration([RecitationSpeed speed = RecitationSpeed.normal]) =>
      getThreshold(speed).targetSeconds;

  double getMinAllowedDuration([RecitationSpeed speed = RecitationSpeed.normal]) =>
      getThreshold(speed).minSeconds;
}

class MaddRule extends TajweedRule {
  const MaddRule({
    super.ruleType = TajweedRuleType.maddNormal,
    super.ruleId = 1,
    required super.goldenLen,
  });
}

class MushaddadGhunnahRule extends TajweedRule {
  final int ghunnaExpected;
  const MushaddadGhunnahRule([this.ghunnaExpected = 2])
      : super(ruleType: TajweedRuleType.ghunnah, ruleId: 10, goldenLen: 2);
}

class ShaddahRule extends TajweedRule {
  const ShaddahRule()
      : super(ruleType: TajweedRuleType.shaddah, ruleId: 9, goldenLen: 1.5);
}

class QalqalahRule extends TajweedRule {
  final int level; // 1: sughra, 2: kubra
  const QalqalahRule([this.level = 1])
      : super(ruleType: TajweedRuleType.qalqalah, ruleId: 8, goldenLen: 1);
}

class PlainLetterRule extends TajweedRule {
  const PlainLetterRule()
      : super(ruleType: TajweedRuleType.plainLetter, ruleId: 11, goldenLen: 0);
}

class TajweedRuleFactory {
  static TajweedRule instantiate(
    WordTajweedRule wRule, [
    RecitationSpeed speed = RecitationSpeed.normal,
  ]) =>
      instantiateFromId(
        wRule.ruleId,
        wRule.goldenLen,
        speed,
        wRule.ghunnaExpected,
        wRule.qalqalahExpected,
      );

  static TajweedRule instantiateFromId(
    int ruleId, [
    num goldenLen = 2,
    RecitationSpeed speed = RecitationSpeed.normal,
    int ghunnaExpected = 0,
    int qalqalahLevel = 0,
  ]) {
    return switch (ruleId) {
      1 => const MaddRule(
          ruleType: TajweedRuleType.maddNormal, ruleId: 1, goldenLen: 2),
      2 => MaddRule(
          ruleType: TajweedRuleType.maddMonfasel,
          ruleId: 2,
          goldenLen: speed.monfaselMaddHarakat),
      3 => MaddRule(
          ruleType: TajweedRuleType.maddMottasel,
          ruleId: 3,
          goldenLen: speed.mottaselMaddHarakat),
      4 => MaddRule(
          ruleType: TajweedRuleType.maddMottaselPause,
          ruleId: 4,
          goldenLen: speed.mottaselMaddPauseHarakat),
      5 => MaddRule(
          ruleType: TajweedRuleType.maddAared,
          ruleId: 5,
          goldenLen: speed.aaredMaddHarakat),
      6 => const MaddRule(
          ruleType: TajweedRuleType.maddLazem, ruleId: 6, goldenLen: 6),
      7 => MaddRule(
          ruleType: TajweedRuleType.maddLeen,
          ruleId: 7,
          goldenLen: speed.leenMaddHarakat),
      8 => QalqalahRule(qalqalahLevel),
      9 => const ShaddahRule(),
      10 => MushaddadGhunnahRule(ghunnaExpected),
      11 => const PlainLetterRule(),
      _ => throw ArgumentError.value(ruleId, 'ruleId'),
    };
  }
}

enum ErrorCategory { tajweed, normal, tashkeel }

enum SpeechErrorType { insert, delete, replace }

enum AlignmentOp { match, replace, delete, insert }

class PhonemeGroupAlignment {
  final AlignmentOp opType;
  final int refIdx;
  final int predIdx;

  const PhonemeGroupAlignment({
    required this.opType,
    required this.refIdx,
    required this.predIdx,
  });
}

class PhoneticSpan {
  final int refStart;
  final int refEnd;
  final String refText;
  final String baseChar;
  final TajweedRuleType ruleType;
  final TajweedRule? rule;
  final bool isQalqalah;
  final int qalqalahLevel; // 0: none, 1: sughra, 2: kubra

  const PhoneticSpan({
    required this.refStart,
    required this.refEnd,
    required this.refText,
    required this.baseChar,
    this.ruleType = TajweedRuleType.other,
    this.rule,
    this.isQalqalah = false,
    this.qalqalahLevel = 0,
  });

  bool get isMadd => ruleType.isMadd;
  bool get isShaddah => ruleType == TajweedRuleType.shaddah;
  bool get isGhunnah => ruleType == TajweedRuleType.ghunnah;
  bool get isPlainLetter => ruleType == TajweedRuleType.plainLetter;
  bool get isHeldDurationRule => isMadd || isShaddah || isGhunnah;
  bool get isTajweedSite => isHeldDurationRule || isQalqalah;
}

class ReciterError {
  final ErrorCategory errorType;
  final SpeechErrorType speechErrorType;
  final TajweedDurationStatus? durationStatus;
  final String expectedPh;
  final String predictedPh;
  final TajweedRule? expectedRule;
  final double? expectedDuration;
  final double? actualDuration;

  const ReciterError({
    required this.errorType,
    required this.speechErrorType,
    this.durationStatus,
    required this.expectedPh,
    required this.predictedPh,
    this.expectedRule,
    this.expectedDuration,
    this.actualDuration,
  });

  int get priority {
    if (errorType == ErrorCategory.normal) return 0;
    if (errorType == ErrorCategory.tashkeel) return 1;
    final rt = expectedRule?.ruleType;
    if (rt != null && rt.isMadd) return 2;
    return switch (rt) {
      TajweedRuleType.ghunnah => 3,
      TajweedRuleType.shaddah => 4,
      TajweedRuleType.qalqalah => 5,
      _ => 6,
    };
  }
}
