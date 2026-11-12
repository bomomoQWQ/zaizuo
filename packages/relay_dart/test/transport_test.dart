import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zaizuo_relay/src/outbox.dart';
import 'package:zaizuo_relay/src/transport.dart';

/// Controlled native-socket boundary. Only members used by RelayTransport are
/// implemented; it deliberately cannot hide an accidental direct socket write.
final class _ControlledSocket extends Stream<Uint8List> implements Socket {
  final input = StreamController<Uint8List>();
  final output = <List<int>>[];
  final _done = Completer<void>();
  Completer<void>? block;
  Completer<void>? nextFlush;
  var flushes = 0;
  var destroyed = false;

  @override
  void add(List<int> bytes) => output.add(List<int>.of(bytes));
  @override
  Future<void> flush() {
    flushes++;
    final signal = nextFlush;
    nextFlush = null;
    signal?.complete();
    return block?.future ?? Future<void>.value();
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      input.stream.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  void destroy() {
    if (destroyed) return;
    destroyed = true;
    block?.complete();
    block = null;
    if (!_done.isCompleted) _done.complete();
    unawaited(input.close());
  }

  @override
  Future<void> close() async => destroy();
  @override
  Future<void> get done => _done.future;
  @override
  InternetAddress get address => InternetAddress.loopbackIPv4;
  @override
  InternetAddress get remoteAddress => InternetAddress.loopbackIPv4;
  @override
  int get port => 1;
  @override
  int get remotePort => 2;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('native pingInterval closes an unresponsive peer without hard sleeps',
      () async {
    final raw = _ControlledSocket();
    final transport = RelayTransport(raw, const Duration(seconds: 1));
    final done = Completer<void>();
    final subscription = transport.webSocket.listen((_) {}, onDone: () {
      transport.inputDone();
      done.complete();
    });
    addTearDown(subscription.cancel);
    addTearDown(raw.destroy);
    final pingFlushed = raw.nextFlush = Completer<void>();
    transport.webSocket.pingInterval = const Duration(milliseconds: 10);
    await pingFlushed.future.timeout(const Duration(seconds: 1));
    expect(raw.output.expand((part) => part).take(2), [0x89, 0]);
    await done.future.timeout(const Duration(seconds: 1));
    expect(transport.webSocket.closeCode, WebSocketStatus.goingAway);
    await transport.close(1001);
    expect(raw.destroyed, isTrue);
  });

  test('transport waits for actual native Socket.flush before completing',
      () async {
    final raw = _ControlledSocket();
    final transport = RelayTransport(raw, const Duration(seconds: 1));
    final subscription =
        transport.webSocket.listen((_) {}, onDone: transport.inputDone);
    addTearDown(subscription.cancel);
    addTearDown(raw.destroy);
    final flushStarted = raw.nextFlush = Completer<void>();
    raw.block = Completer<void>();
    var completed = false;
    final write = transport.write('opaque').then((_) => completed = true);
    await flushStarted.future;
    expect(completed, isFalse);
    expect(raw.output, isNotEmpty);
    raw.block!.complete();
    raw.block = null;
    await write;
    expect(raw.output.expand((part) => part).toList(),
        [0x81, 6, ...utf8.encode('opaque')]);
    // Mark the fake peer's incoming side complete to avoid an artificial wait.
    transport.inputDone();
    await transport.close(1001);
    expect(raw.destroyed, isTrue);
  });

  test('blocked output pauses raw input including SDK-generated pong pressure',
      () async {
    final raw = _ControlledSocket();
    final socket = FlushingSocket(raw, const Duration(seconds: 1));
    final input = socket.listen((_) {});
    addTearDown(input.cancel);
    addTearDown(raw.destroy);
    final flushStarted = raw.nextFlush = Completer<void>();
    raw.block = Completer<void>();
    final sending = socket.addStream(Stream<List<int>>.value([0x89, 0]));
    await flushStarted.future;
    expect(raw.input.isPaused, isTrue);
    raw.block!.complete();
    raw.block = null;
    await sending;
    expect(raw.input.isPaused, isFalse);
  });

  test('queue overflow reaches native wire as 1013, not Dart-rejected 1011',
      () async {
    final raw = _ControlledSocket();
    final transport = RelayTransport(raw, const Duration(seconds: 1));
    final subscription =
        transport.webSocket.listen((_) {}, onDone: transport.inputDone);
    addTearDown(subscription.cancel);
    addTearDown(raw.destroy);
    Future<void>? closing;
    final outbox = BoundedOutbox(
      capacity: 1,
      timeout: const Duration(seconds: 1),
      write: transport.write,
      onBackpressure: () {
        transport.inputDone();
        closing = transport.close(1013);
      },
    );
    final flushStarted = raw.nextFlush = Completer<void>();
    raw.block = Completer<void>();
    expect(outbox.add('first'), isTrue);
    await flushStarted.future;
    expect(outbox.add('second'), isFalse);
    expect(closing, isNotNull);
    raw.block!.complete();
    raw.block = null;
    await closing;
    final wire = raw.output.expand((part) => part).toList();
    expect(wire, [0x81, 5, ...utf8.encode('first'), 0x88, 2, 0x03, 0xf5]);
    expect(raw.destroyed, isTrue);
  });

  test('a blocked close destroys native socket within configured grace',
      () async {
    final raw = _ControlledSocket();
    final transport = RelayTransport(raw, const Duration(milliseconds: 10));
    final subscription =
        transport.webSocket.listen((_) {}, onDone: transport.inputDone);
    addTearDown(subscription.cancel);
    addTearDown(raw.destroy);
    raw.block = Completer<void>();
    // No fake peer close is injected: both output and input can stay stuck.
    await transport.close(1001);
    expect(raw.destroyed, isTrue);
  });
}
