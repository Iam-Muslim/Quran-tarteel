// lib/src/config.dart
// Pure-Dart configuration models for DTW alignment, auto-reanchor, and Tajweed verification.

enum RecitationSpeed {
  fast,
  normal,
  slow;

  int get aaredMaddHarakat => switch (this) {
        RecitationSpeed.fast => 2,
        RecitationSpeed.normal => 4,
        RecitationSpeed.slow => 6,
      };

  int get leenMaddHarakat => switch (this) {
        RecitationSpeed.fast => 2,
        RecitationSpeed.normal => 4,
        RecitationSpeed.slow => 6,
      };

  int get monfaselMaddHarakat => switch (this) {
        RecitationSpeed.fast => 2,
        RecitationSpeed.normal => 4,
        RecitationSpeed.slow => 5,
      };

  int get mottaselMaddHarakat => switch (this) {
        RecitationSpeed.fast => 4,
        RecitationSpeed.normal => 4,
        RecitationSpeed.slow => 5,
      };

  int get mottaselMaddPauseHarakat => switch (this) {
        RecitationSpeed.fast => 4,
        RecitationSpeed.normal => 4,
        RecitationSpeed.slow => 6,
      };

  double get harakahBaseSeconds => switch (this) {
        RecitationSpeed.fast => 0.12,
        RecitationSpeed.normal => 0.15,
        RecitationSpeed.slow => 0.18,
      };
}

class TajweedConfig {
  final bool checkMadd;
  final bool checkTashkeel;
  final bool checkGhunnah;
  final bool checkShaddah;
  final bool checkQalqalah;
  final bool checkLetterSwap;
  final bool checkPlainLetters;
  final double? qalqalahTau;

  const TajweedConfig({
    this.checkMadd = true,
    this.checkTashkeel = true,
    this.checkGhunnah = true,
    this.checkShaddah = true,
    this.checkQalqalah = true,
    this.checkLetterSwap = true,
    this.checkPlainLetters = true,
    this.qalqalahTau,
  });

  const TajweedConfig.none({this.qalqalahTau})
      : checkMadd = false,
        checkTashkeel = false,
        checkGhunnah = false,
        checkShaddah = false,
        checkQalqalah = false,
        checkLetterSwap = false,
        checkPlainLetters = false;

  bool get isAnyCheckEnabled =>
      checkMadd ||
      checkTashkeel ||
      checkGhunnah ||
      checkShaddah ||
      checkQalqalah ||
      checkLetterSwap ||
      checkPlainLetters;

  TajweedConfig copyWith({
    bool? checkMadd,
    bool? checkTashkeel,
    bool? checkGhunnah,
    bool? checkShaddah,
    bool? checkQalqalah,
    bool? checkLetterSwap,
    bool? checkPlainLetters,
    double? qalqalahTau,
  }) {
    return TajweedConfig(
      checkMadd: checkMadd ?? this.checkMadd,
      checkTashkeel: checkTashkeel ?? this.checkTashkeel,
      checkGhunnah: checkGhunnah ?? this.checkGhunnah,
      checkShaddah: checkShaddah ?? this.checkShaddah,
      checkQalqalah: checkQalqalah ?? this.checkQalqalah,
      checkLetterSwap: checkLetterSwap ?? this.checkLetterSwap,
      checkPlainLetters: checkPlainLetters ?? this.checkPlainLetters,
      qalqalahTau: qalqalahTau ?? this.qalqalahTau,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TajweedConfig &&
          runtimeType == other.runtimeType &&
          checkMadd == other.checkMadd &&
          checkTashkeel == other.checkTashkeel &&
          checkGhunnah == other.checkGhunnah &&
          checkShaddah == other.checkShaddah &&
          checkQalqalah == other.checkQalqalah &&
          checkLetterSwap == other.checkLetterSwap &&
          checkPlainLetters == other.checkPlainLetters &&
          qalqalahTau == other.qalqalahTau;

  @override
  int get hashCode => Object.hash(
        checkMadd,
        checkTashkeel,
        checkGhunnah,
        checkShaddah,
        checkQalqalah,
        checkLetterSwap,
        checkPlainLetters,
        qalqalahTau,
      );
}

enum MatchingStrictness {
  easy,
  normal,
  hard,
}

class MatchingPolicy {
  final double defaultMaxPathCost;
  final double shortWordPathCost;
  final double mediumWordPathCost;
  final double skipMaxPathCost;
  final int maxSkipWords;
  final double acousticConfusionCost;
  final double minAltProbThreshold;
  final double standardInsertionCost;
  final double standardDeletionCost;
  final double maxTokenDurationAllowed;

  final bool enforceAcousticOverlapLimit;
  final int minConsonantsForAcousticOverlap;
  final double highConfidenceThreshold;
  final bool allowSingleLowConfSlipOnLongWords;
  final int maxLowConfNonAcousticSubs;
  final bool allowMissingConsonantOnLongWords;
  final double minMatchedConsonantRatio;
  final int shortWordMaxConsonants;
  final int mediumWordMaxConsonants;
  final int maxAcousticOverlapSubs;
  final int minLongWordConsonants;

  const MatchingPolicy({
    this.defaultMaxPathCost = 0.30,
    this.shortWordPathCost = 0.26,
    this.mediumWordPathCost = 0.30,
    this.skipMaxPathCost = 0.25,
    this.maxSkipWords = 2,
    this.acousticConfusionCost = 0.20,
    this.minAltProbThreshold = 0.02,
    this.standardInsertionCost = 0.75,
    this.standardDeletionCost = 1.00,
    this.maxTokenDurationAllowed = 2.5,
    this.enforceAcousticOverlapLimit = true,
    this.minConsonantsForAcousticOverlap = 2,
    this.highConfidenceThreshold = 0.50,
    this.allowSingleLowConfSlipOnLongWords = true,
    this.maxLowConfNonAcousticSubs = 1,
    this.allowMissingConsonantOnLongWords = true,
    this.minMatchedConsonantRatio = 0.65,
    this.shortWordMaxConsonants = 2,
    this.mediumWordMaxConsonants = 4,
    this.maxAcousticOverlapSubs = 1,
    this.minLongWordConsonants = 5,
  });

  factory MatchingPolicy.fromStrictness(MatchingStrictness strictness) =>
      switch (strictness) {
        MatchingStrictness.easy => const MatchingPolicy(
            defaultMaxPathCost: 0.38,
            shortWordPathCost: 0.35,
            mediumWordPathCost: 0.35,
            skipMaxPathCost: 0.30,
            maxSkipWords: 2,
            acousticConfusionCost: 0.15,
            minAltProbThreshold: 0.015,
            standardInsertionCost: 0.60,
            standardDeletionCost: 0.80,
            maxTokenDurationAllowed: 3.0,
            enforceAcousticOverlapLimit: false,
            highConfidenceThreshold: 0.70,
            allowSingleLowConfSlipOnLongWords: true,
            maxLowConfNonAcousticSubs: 2,
            allowMissingConsonantOnLongWords: true,
            minMatchedConsonantRatio: 0.55,
          ),
        MatchingStrictness.normal => const MatchingPolicy(),
        MatchingStrictness.hard => const MatchingPolicy(
            defaultMaxPathCost: 0.22,
            shortWordPathCost: 0.20,
            mediumWordPathCost: 0.22,
            skipMaxPathCost: 0.18,
            maxSkipWords: 1,
            acousticConfusionCost: 0.35,
            minAltProbThreshold: 0.15,
            standardInsertionCost: 1.00,
            standardDeletionCost: 1.00,
            maxTokenDurationAllowed: 2.0,
            enforceAcousticOverlapLimit: true,
            minConsonantsForAcousticOverlap: 3,
            allowSingleLowConfSlipOnLongWords: false,
            allowMissingConsonantOnLongWords: false,
          ),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MatchingPolicy &&
          runtimeType == other.runtimeType &&
          defaultMaxPathCost == other.defaultMaxPathCost &&
          shortWordPathCost == other.shortWordPathCost &&
          mediumWordPathCost == other.mediumWordPathCost &&
          skipMaxPathCost == other.skipMaxPathCost &&
          maxSkipWords == other.maxSkipWords &&
          acousticConfusionCost == other.acousticConfusionCost &&
          minAltProbThreshold == other.minAltProbThreshold &&
          standardInsertionCost == other.standardInsertionCost &&
          standardDeletionCost == other.standardDeletionCost &&
          maxTokenDurationAllowed == other.maxTokenDurationAllowed &&
          enforceAcousticOverlapLimit == other.enforceAcousticOverlapLimit &&
          minConsonantsForAcousticOverlap ==
              other.minConsonantsForAcousticOverlap &&
          highConfidenceThreshold == other.highConfidenceThreshold &&
          allowSingleLowConfSlipOnLongWords ==
              other.allowSingleLowConfSlipOnLongWords &&
          maxLowConfNonAcousticSubs == other.maxLowConfNonAcousticSubs &&
          allowMissingConsonantOnLongWords ==
              other.allowMissingConsonantOnLongWords &&
          minMatchedConsonantRatio == other.minMatchedConsonantRatio &&
          shortWordMaxConsonants == other.shortWordMaxConsonants &&
          mediumWordMaxConsonants == other.mediumWordMaxConsonants &&
          maxAcousticOverlapSubs == other.maxAcousticOverlapSubs &&
          minLongWordConsonants == other.minLongWordConsonants;

  @override
  int get hashCode => Object.hashAll([
        defaultMaxPathCost,
        shortWordPathCost,
        mediumWordPathCost,
        skipMaxPathCost,
        maxSkipWords,
        acousticConfusionCost,
        minAltProbThreshold,
        standardInsertionCost,
        standardDeletionCost,
        maxTokenDurationAllowed,
        enforceAcousticOverlapLimit,
        minConsonantsForAcousticOverlap,
        highConfidenceThreshold,
        allowSingleLowConfSlipOnLongWords,
        maxLowConfNonAcousticSubs,
        allowMissingConsonantOnLongWords,
        minMatchedConsonantRatio,
        shortWordMaxConsonants,
        mediumWordMaxConsonants,
        maxAcousticOverlapSubs,
        minLongWordConsonants,
      ]);
}

class ReanchorPolicy {
  final int minQueryLen;
  final int maxMinQueryLen;
  final double maxDistRatio;
  final int fullQueryMaxLen;
  final int frontQueryMaxLen;
  final int tailQueryMaxLen;
  final int ambiguityWordGap;
  final int ambiguityDistGap;

  const ReanchorPolicy({
    this.minQueryLen = 8,
    this.maxMinQueryLen = 18,
    this.maxDistRatio = 0.22,
    this.fullQueryMaxLen = 64,
    this.frontQueryMaxLen = 36,
    this.tailQueryMaxLen = 28,
    this.ambiguityWordGap = 2,
    this.ambiguityDistGap = 3,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReanchorPolicy &&
          runtimeType == other.runtimeType &&
          minQueryLen == other.minQueryLen &&
          maxMinQueryLen == other.maxMinQueryLen &&
          maxDistRatio == other.maxDistRatio &&
          fullQueryMaxLen == other.fullQueryMaxLen &&
          frontQueryMaxLen == other.frontQueryMaxLen &&
          tailQueryMaxLen == other.tailQueryMaxLen &&
          ambiguityWordGap == other.ambiguityWordGap &&
          ambiguityDistGap == other.ambiguityDistGap;

  @override
  int get hashCode => Object.hash(
        minQueryLen,
        maxMinQueryLen,
        maxDistRatio,
        fullQueryMaxLen,
        frontQueryMaxLen,
        tailQueryMaxLen,
        ambiguityWordGap,
        ambiguityDistGap,
      );
}

class TrackerConfig {
  static const int defaultReanchorStallThreshold = 100;

  final RecitationSpeed recitationSpeed;
  final MatchingStrictness matchingStrictness;
  final MatchingPolicy? _policy;
  final bool enableAutoReanchor;
  final int reanchorStallThreshold;
  final ReanchorPolicy reanchor;
  final TajweedConfig tajweed;

  const TrackerConfig({
    this.recitationSpeed = RecitationSpeed.normal,
    this.matchingStrictness = MatchingStrictness.normal,
    MatchingPolicy? policy,
    this.enableAutoReanchor = false,
    this.reanchorStallThreshold = defaultReanchorStallThreshold,
    this.reanchor = const ReanchorPolicy(),
    this.tajweed = const TajweedConfig(),
  }) : _policy = policy;

  MatchingPolicy get policy =>
      _policy ?? MatchingPolicy.fromStrictness(matchingStrictness);

  factory TrackerConfig.normal({
    RecitationSpeed speed = RecitationSpeed.normal,
    MatchingPolicy? policy,
    bool enableAutoReanchor = false,
    int reanchorStallThreshold = defaultReanchorStallThreshold,
    ReanchorPolicy reanchor = const ReanchorPolicy(),
    TajweedConfig tajweed = const TajweedConfig(),
  }) =>
      TrackerConfig(
        recitationSpeed: speed,
        matchingStrictness: MatchingStrictness.normal,
        policy: policy,
        enableAutoReanchor: enableAutoReanchor,
        reanchorStallThreshold: reanchorStallThreshold,
        reanchor: reanchor,
        tajweed: tajweed,
      );

  factory TrackerConfig.fast({
    MatchingPolicy? policy,
    bool enableAutoReanchor = true,
    int reanchorStallThreshold = defaultReanchorStallThreshold,
    ReanchorPolicy reanchor = const ReanchorPolicy(),
    TajweedConfig tajweed = const TajweedConfig(),
  }) =>
      TrackerConfig(
        recitationSpeed: RecitationSpeed.fast,
        matchingStrictness: MatchingStrictness.easy,
        policy: policy,
        enableAutoReanchor: enableAutoReanchor,
        reanchorStallThreshold: reanchorStallThreshold,
        reanchor: reanchor,
        tajweed: tajweed,
      );

  factory TrackerConfig.easy({
    RecitationSpeed speed = RecitationSpeed.fast,
    MatchingPolicy? policy,
    bool enableAutoReanchor = false,
    int reanchorStallThreshold = defaultReanchorStallThreshold,
    ReanchorPolicy reanchor = const ReanchorPolicy(),
    TajweedConfig tajweed = const TajweedConfig(),
  }) =>
      TrackerConfig(
        recitationSpeed: speed,
        matchingStrictness: MatchingStrictness.easy,
        policy: policy,
        enableAutoReanchor: enableAutoReanchor,
        reanchorStallThreshold: reanchorStallThreshold,
        reanchor: reanchor,
        tajweed: tajweed,
      );

  factory TrackerConfig.strict({
    RecitationSpeed speed = RecitationSpeed.slow,
    MatchingPolicy? policy,
    bool enableAutoReanchor = false,
    int reanchorStallThreshold = defaultReanchorStallThreshold,
    ReanchorPolicy reanchor = const ReanchorPolicy(),
    TajweedConfig tajweed = const TajweedConfig(),
  }) =>
      TrackerConfig(
        recitationSpeed: speed,
        matchingStrictness: MatchingStrictness.hard,
        policy: policy,
        enableAutoReanchor: enableAutoReanchor,
        reanchorStallThreshold: reanchorStallThreshold,
        reanchor: reanchor,
        tajweed: tajweed,
      );

  double get defaultMaxPathCost => policy.defaultMaxPathCost;
  double get shortWordPathCost => policy.shortWordPathCost;
  double get mediumWordPathCost => policy.mediumWordPathCost;
  int get maxSkipWords => policy.maxSkipWords;
  double get acousticConfusionCost => policy.acousticConfusionCost;
  double get minAltProbThreshold => policy.minAltProbThreshold;
  double get standardInsertionCost => policy.standardInsertionCost;
  double get standardDeletionCost => policy.standardDeletionCost;
  double get maxTokenDurationAllowed => policy.maxTokenDurationAllowed;

  TrackerConfig copyWith({
    RecitationSpeed? recitationSpeed,
    MatchingStrictness? matchingStrictness,
    MatchingPolicy? policy,
    bool? enableAutoReanchor,
    int? reanchorStallThreshold,
    ReanchorPolicy? reanchor,
    TajweedConfig? tajweed,
  }) {
    return TrackerConfig(
      recitationSpeed: recitationSpeed ?? this.recitationSpeed,
      matchingStrictness: matchingStrictness ?? this.matchingStrictness,
      policy: policy ?? _policy,
      enableAutoReanchor: enableAutoReanchor ?? this.enableAutoReanchor,
      reanchorStallThreshold:
          reanchorStallThreshold ?? this.reanchorStallThreshold,
      reanchor: reanchor ?? this.reanchor,
      tajweed: tajweed ?? this.tajweed,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrackerConfig &&
          runtimeType == other.runtimeType &&
          recitationSpeed == other.recitationSpeed &&
          matchingStrictness == other.matchingStrictness &&
          _policy == other._policy &&
          enableAutoReanchor == other.enableAutoReanchor &&
          reanchorStallThreshold == other.reanchorStallThreshold &&
          reanchor == other.reanchor &&
          tajweed == other.tajweed;

  @override
  int get hashCode => Object.hash(
        recitationSpeed,
        matchingStrictness,
        _policy,
        enableAutoReanchor,
        reanchorStallThreshold,
        reanchor,
        tajweed,
      );
}
