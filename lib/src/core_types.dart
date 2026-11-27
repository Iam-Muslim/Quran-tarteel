// lib/src/core_types.dart
// Typed domain codes, compact 32-bit coordinates, phonetic predicates, and acoustic frames.

enum QuranTarteelErrorCode {
  uninitialized,
  disposed,
  invalidReferenceData,
  missingCalibrationThreshold,
  missingAcousticHead,
  isolateStartTimeout,
}

class QuranTarteelException implements Exception {
  final QuranTarteelErrorCode code;
  final Object? cause;

  const QuranTarteelException(this.code, [this.cause]);

  @override
  bool operator ==(Object other) =>
      other is QuranTarteelException &&
      other.code == code &&
      other.cause == cause;

  @override
  int get hashCode => Object.hash(code, cause);
}

/// Compact 32-bit packing for `(surah, ayah, word0)` and `(surah, ayah)` keys.
abstract final class QuranCoordinate {
  static int packWordKey(int surah, int ayah, int word0) =>
      ((surah & 0xFF) << 20) | ((ayah & 0xFFF) << 8) | (word0 & 0xFF);

  static (int surah, int ayah, int word0) unpackWordKey(int key) => (
        (key >> 20) & 0xFF,
        (key >> 8) & 0xFFF,
        key & 0xFF,
      );

  static int packAyahKey(int surah, int ayah) =>
      ((surah & 0xFFFF) << 16) | (ayah & 0xFFFF);

  static (int surah, int ayah) unpackAyahKey(int key) => (
        (key >> 16) & 0xFFFF,
        key & 0xFFFF,
      );
}

/// Stateless tj3 phonetic character predicates and UTF-16 code-unit constants.
abstract final class PhoneticSymbols {
  static const int wordBarCodeUnit = 0x007C; // '|'
  static const int vowelACodeUnit = 0x61; // 'a'
  static const int vowelICodeUnit = 0x69; // 'i'
  static const int vowelUCodeUnit = 0x75; // 'u'
  static const int nunCodeUnit = 0x0646; // 'ن'
  static const int nasalNunCodeUnit = 0x06BA; // 'ں'
  static const int meemCodeUnit = 0x0645; // 'م'

  static bool isControlToken(String token) =>
      token.isEmpty ||
      token.startsWith('<') ||
      token == '|' ||
      token == 'eps';

  static bool isVowelChar(int code) =>
      code == vowelACodeUnit || code == vowelICodeUnit || code == vowelUCodeUnit;

  static bool isTanweenNasalChar(int code) =>
      code == nunCodeUnit || code == nasalNunCodeUnit || code == meemCodeUnit;

  static bool isMaddLongVowel(String text, int idx) {
    if (idx < 0 || idx >= text.length) return false;
    final int code = text.codeUnitAt(idx);
    if (!isVowelChar(code)) return false;
    if (idx > 0 && text.codeUnitAt(idx - 1) == code) return true;
    if (idx + 1 < text.length && text.codeUnitAt(idx + 1) == code) return true;
    return false;
  }

  static bool isTashkeelChar(String text, int idx) {
    if (idx < 0 || idx >= text.length) return false;
    return isVowelChar(text.codeUnitAt(idx)) && !isMaddLongVowel(text, idx);
  }
}

/// Frame-averaged neural metrics for one recognized token from TajweedFormer V4
/// active heads (`log_probs`, `attr_qalqalah`, `conf`).
class TokenNeuralAcoustics {
  final double qalqalahScore;
  final double? confScore;
  final Map<int, double> altProbs;

  const TokenNeuralAcoustics({
    this.qalqalahScore = 0.0,
    this.confScore,
    this.altProbs = const {},
  });

  double probOf(int codeUnit) => altProbs[codeUnit] ?? 0.0;
}

/// Unified decoded acoustic payload consumed by [QuranScorer] or standalone ASR consumers.
class TranscriptionResult {
  final String text;
  final bool isFinal;
  final int startTime;
  final List<String> tokens;
  final List<double> timestamps;
  final List<double> durations;
  final List<TokenNeuralAcoustics> neuralAcoustics;
  final int streamEpoch;
  final double? audioElapsedSeconds;

  const TranscriptionResult({
    required this.text,
    this.isFinal = false,
    this.startTime = 0,
    this.tokens = const [],
    this.timestamps = const [],
    this.durations = const [],
    this.neuralAcoustics = const [],
    this.streamEpoch = 0,
    this.audioElapsedSeconds,
  });
}

/// Pure-Dart token vocabulary matching `TajweedTokens` from `quranlab_tajweedformer`.
class PhonemeVocabulary {
  final List<String> names;
  final int blank;
  final int? wordBar;

  const PhonemeVocabulary({
    required this.names,
    required this.blank,
    this.wordBar,
  });

  int get count => names.length;

  String name(int id) {
    RangeError.checkValidIndex(id, names, 'id');
    return names[id];
  }

  int? id(String name) {
    final i = names.indexOf(name);
    return i < 0 ? null : i;
  }
}
