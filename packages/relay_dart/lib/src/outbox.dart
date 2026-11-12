import 'dart:async';
import 'dart:collection';

/// A finite application queue, with exactly one awaited transport write at a
/// time. The in-flight item counts toward the capacity. Internal for testing.
final class BoundedOutbox {
  BoundedOutbox({
    required this.capacity,
    required this.timeout,
    required this.write,
    required this.onBackpressure,
  });

  final int capacity;
  final Duration timeout;
  final Future<void> Function(String) write;
  final void Function() onBackpressure;
  final Queue<String> _messages = Queue<String>();
  bool _running = false;
  bool _stopped = false;

  int get pending => _messages.length;

  bool add(String message) {
    if (_stopped) return false;
    if (_messages.length >= capacity) {
      _fail();
      return false;
    }
    _messages.addLast(message);
    if (!_running) {
      _running = true;
      unawaited(_pump());
    }
    return true;
  }

  void stop() {
    _stopped = true;
    _messages.clear();
  }

  void _fail() {
    if (_stopped) return;
    stop();
    onBackpressure();
  }

  Future<void> _pump() async {
    try {
      while (!_stopped && _messages.isNotEmpty) {
        await write(_messages.first).timeout(timeout);
        if (!_stopped) _messages.removeFirst();
      }
    } catch (_) {
      // No exception text or message data is logged or returned to clients.
      _fail();
    } finally {
      _running = false;
    }
  }
}
