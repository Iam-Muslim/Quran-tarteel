// lib/src/dictation/worker_transport_web.dart
import 'dart:async';

import 'sequencer.dart';
import 'worker.dart';

class AlignmentWorkerTransport {
  final void Function(IsolateEvent event) onEvent;

  StreamController<IsolateCommand>? _commandPort;
  final List<IsolateCommand> _pendingCommands = [];

  AlignmentWorkerTransport({required this.onEvent});

  Future<void> start() async {
    _commandPort = StreamController<IsolateCommand>();
    final sequencer = DictationSequencer(onEvent);

    _commandPort!.stream.listen((command) {
      try {
        sequencer.handleCommand(command);
      } catch (e, stack) {
        onEvent(IsolateErrorEvent(e, stack));
      }
    });

    for (final cmd in _pendingCommands) {
      _commandPort!.add(cmd);
    }
    _pendingCommands.clear();
  }

  void send(IsolateCommand command) {
    if (_commandPort != null) {
      _commandPort!.add(command);
    } else {
      _pendingCommands.add(command);
    }
  }

  void stop() {
    send(const StopIsolateCommand());
    _pendingCommands.clear();
    _commandPort?.close();
    _commandPort = null;
  }
}
