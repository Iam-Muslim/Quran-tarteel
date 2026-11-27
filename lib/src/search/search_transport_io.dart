// lib/src/search/search_transport_io.dart
import 'dart:async';
import 'dart:isolate';

import 'fuzzy_matcher.dart';

void _phoneticWorkerEntrypoint(List<dynamic> args) {
  final SendPort initSendPort = args[0] as SendPort;
  final SendPort responseSendPort = args[1] as SendPort;
  final String refPhNorm = args[2] as String;

  final commandPort = ReceivePort();
  initSendPort.send(commandPort.sendPort);

  commandPort.listen((message) {
    if (message is List && message.length == 3) {
      final int reqId = message[0] as int;
      final String normQuery = message[1] as String;
      final int maxEdits = message[2] as int;

      try {
        final List<FuzzyMatch> matches =
            findNearMatches(normQuery, refPhNorm, maxEdits);
        responseSendPort.send([reqId, true, matches]);
      } catch (e, st) {
        responseSendPort.send([reqId, false, e, st]);
      }
    }
  });
}

class SearchWorkerTransport {
  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _responsePort;
  int _requestId = 0;
  final Map<int, Completer<List<FuzzyMatch>>> _pendingRequests = {};
  bool _isReady = false;

  bool get isReady => _isReady;

  Future<void> start(String refPhNorm) async {
    if (_isReady) return;

    final initPort = ReceivePort();
    _responsePort = ReceivePort();

    _isolate = await Isolate.spawn(
      _phoneticWorkerEntrypoint,
      [initPort.sendPort, _responsePort!.sendPort, refPhNorm],
    );

    _sendPort = await initPort.first as SendPort;
    initPort.close();

    _responsePort!.listen((message) {
      if (message is List && message.length >= 3) {
        final int reqId = message[0] as int;
        final bool ok = message[1] as bool;
        final completer = _pendingRequests.remove(reqId);
        if (completer == null || completer.isCompleted) return;
        if (ok) {
          completer.complete(message[2] as List<FuzzyMatch>);
        } else {
          final Object err = message[2] as Object;
          final StackTrace? st =
              message.length >= 4 ? message[3] as StackTrace? : null;
          completer.completeError(err, st);
        }
      }
    });

    _isReady = true;
  }

  Future<List<FuzzyMatch>> search(String query, int maxEdits) {
    if (!_isReady || _sendPort == null) {
      throw StateError('SearchWorkerTransport has not been started.');
    }
    final int reqId = ++_requestId;
    final completer = Completer<List<FuzzyMatch>>();
    _pendingRequests[reqId] = completer;
    _sendPort!.send([reqId, query, maxEdits]);
    return completer.future.timeout(const Duration(milliseconds: 1500));
  }

  void dispose() {
    _isReady = false;
    for (final c in _pendingRequests.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('SearchWorkerTransport disposed.'));
      }
    }
    _pendingRequests.clear();
    _responsePort?.close();
    _responsePort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
  }
}
