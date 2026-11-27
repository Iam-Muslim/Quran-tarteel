// lib/src/dictation/worker_transport_io.dart
import 'dart:async';
import 'dart:isolate';

import '../core_types.dart';
import 'sequencer.dart';
import 'worker.dart';

void _alignmentWorkerEntrypoint(SendPort mainSendPort) {
  final commandPort = ReceivePort();
  mainSendPort.send(commandPort.sendPort);

  final sequencer = DictationSequencer(mainSendPort.send);

  commandPort.listen((rawMessage) {
    if (rawMessage is! IsolateCommand) return;

    try {
      if (!sequencer.handleCommand(rawMessage)) {
        Isolate.current.kill();
      }
    } catch (e, stack) {
      mainSendPort.send(IsolateErrorEvent(e, stack));
    }
  });
}

class AlignmentWorkerTransport {
  final void Function(IsolateEvent event) onEvent;

  SendPort? _sendPort;
  Isolate? _isolate;
  ReceivePort? _receivePort;
  final List<IsolateCommand> _pendingCommands = [];

  AlignmentWorkerTransport({required this.onEvent});

  Future<void> start() async {
    final receivePort = ReceivePort();
    _receivePort = receivePort;
    final completer = Completer<void>();

    _isolate = await Isolate.spawn(
      _alignmentWorkerEntrypoint,
      receivePort.sendPort,
    );

    receivePort.listen((message) {
      if (message is SendPort) {
        _sendPort = message;
        for (final cmd in _pendingCommands) {
          _sendPort!.send(cmd);
        }
        _pendingCommands.clear();
        if (!completer.isCompleted) completer.complete();
      } else if (message is IsolateEvent) {
        onEvent(message);
      }
    });

    try {
      await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw const QuranTarteelException(
          QuranTarteelErrorCode.isolateStartTimeout,
        ),
      );
    } catch (_) {
      stop();
      rethrow;
    }
  }

  void send(IsolateCommand command) {
    if (_sendPort != null) {
      _sendPort!.send(command);
    } else {
      _pendingCommands.add(command);
    }
  }

  void stop() {
    if (_sendPort != null) {
      _sendPort!.send(const StopIsolateCommand());
    }
    _pendingCommands.clear();
    _receivePort?.close();
    _receivePort = null;
    _isolate?.kill();
    _isolate = null;
    _sendPort = null;
  }
}
