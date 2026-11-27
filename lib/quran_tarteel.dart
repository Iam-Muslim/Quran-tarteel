// lib/quran_tarteel.dart
// Direct bridge between quranlab_tajweedformer SDK 4.0 and pure-Dart Quran scoring/search.

import 'dart:async';

import 'package:quranlab_tajweedformer/quranlab_tajweedformer.dart';

import 'scoring.dart';
import 'src/sdk_bridge.dart';

export 'package:quranlab_tajweedformer/quranlab_tajweedformer.dart';
export 'scoring.dart';
export 'src/audio_processor.dart' show AudioProcessor, Pcm16StreamNormalizer;
export 'src/sdk_bridge.dart';

/// Callback invoked when a bound [TajweedSession] emits a stream error.
typedef TajweedSessionErrorCallback = void Function(
  Object error,
  StackTrace stackTrace,
);

/// Lightweight binder connecting an open [TajweedSession] directly to [QuranScorer]
/// without owning `TajweedClient`, `TajweedModel`, or hiding SDK errors.
class TajweedSessionBinder {
  /// Decoder converting incoming SDK chunks/heads to [TranscriptionResult]s.
  final TajweedTakeDecoder decoder;

  /// Scorer aligned and graded from decoded transcripts.
  final QuranScorer scorer;

  /// Optional synchronous hook invoked whenever [TajweedSession.chunks] or
  /// [TajweedSession.events] emits an error.
  final TajweedSessionErrorCallback? onError;

  StreamSubscription<TajweedChunk>? _chunkSub;
  StreamSubscription<TajweedEvent>? _eventSub;
  int _streamEpoch = 0;
  bool _sawFinalChunk = false;
  bool _isDisposed = false;

  final StreamController<TranscriptionResult> _transcriptController =
      StreamController<TranscriptionResult>.broadcast();
  final StreamController<TajweedEvent> _eventController =
      StreamController<TajweedEvent>.broadcast();

  /// Decoded streaming & final transcripts produced by the attached session.
  /// Any chunk-stream errors from the SDK are forwarded onto this stream.
  Stream<TranscriptionResult> get onTranscription => _transcriptController.stream;

  /// Forwarded SDK session lifecycle events (`TajweedBackendChanged`, `TajweedEnded`, etc.).
  /// Any event-stream errors from the SDK are forwarded onto this stream.
  Stream<TajweedEvent> get onSessionEvent => _eventController.stream;

  /// Whether a live [TajweedSession] is currently attached.
  bool get isAttached => _chunkSub != null || _eventSub != null;

  TajweedSessionBinder({
    required TajweedTokens vocab,
    required this.scorer,
    bool requireQalqalahHead = true,
    double minKeepProb = TajweedTakeDecoder.defaultMinKeepProb,
    this.onError,
  }) : decoder = TajweedTakeDecoder(
          vocab: vocab,
          requireQalqalahHead: requireQalqalahHead,
          minKeepProb: minKeepProb,
        );

  void _reportError(
    StreamController<dynamic> controller,
    Object error,
    StackTrace stackTrace,
  ) {
    onError?.call(error, stackTrace);
    if (!controller.isClosed) {
      controller.addError(error, stackTrace);
    }
  }

  /// Binds a live [TajweedSession] (`model.listen()`, `model.session()`, etc.)
  /// to [scorer], decoding chunks and forwarding errors without swallowing them.
  Future<void> attach(TajweedSession session) async {
    if (_isDisposed) {
      throw const QuranTarteelException(QuranTarteelErrorCode.disposed);
    }
    await detach();
    _streamEpoch++;
    _sawFinalChunk = false;
    decoder.resetTake();
    scorer.resetBuffer();

    final int epoch = _streamEpoch;

    _chunkSub = session.chunks.listen(
      (chunk) {
        try {
          final result = decoder.decodeChunk(chunk, streamEpoch: epoch);
          if (result.isFinal) _sawFinalChunk = true;
          if (!_transcriptController.isClosed) {
            _transcriptController.add(result);
          }
          scorer.feedTranscript(result);
        } catch (error, stackTrace) {
          _reportError(_transcriptController, error, stackTrace);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _reportError(_transcriptController, error, stackTrace);
      },
    );

    _eventSub = session.events.listen(
      (event) {
        if (event is TajweedBackendChanged && event.fromChunk == 0) {
          decoder.resetTake();
        }
        if (!_eventController.isClosed) {
          _eventController.add(event);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _reportError(_eventController, error, stackTrace);
      },
    );
  }

  /// Finishes [session] and feeds its final decoded heads to [scorer] if no
  /// final chunk was already emitted.
  Future<TajweedHeads> finishAndFlush(TajweedSession session) async {
    if (_isDisposed) {
      throw const QuranTarteelException(QuranTarteelErrorCode.disposed);
    }
    final int epoch = _streamEpoch;
    final heads = await session.finish();
    if (!_sawFinalChunk) {
      final result = decoder.decodeFinishedHeads(heads, streamEpoch: epoch);
      if (!_transcriptController.isClosed) {
        _transcriptController.add(result);
      }
      scorer.feedTranscript(result);
    }
    await detach();
    return heads;
  }

  /// Detaches any active SDK chunk/event subscriptions without disposing [scorer].
  Future<void> detach() async {
    await _chunkSub?.cancel();
    _chunkSub = null;
    await _eventSub?.cancel();
    _eventSub = null;
  }

  /// Detaches the active session and closes binder broadcast streams.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    await detach();
    if (!_transcriptController.isClosed) {
      await _transcriptController.close();
    }
    if (!_eventController.isClosed) {
      await _eventController.close();
    }
  }
}
