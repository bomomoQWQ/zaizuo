import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_relay/zaizuo_relay.dart';
import 'package:zaizuo_runtime/src/relay_client.dart';

const _token = 'only-local-relay-link-test-token-00000000';
const _guard = Duration(seconds: 5);

class _Fixture {
  _Fixture(this.root, this.identity, this.device, this.key, this.sender,
      this.receiver);
  final Directory root;
  final Identity identity;
  final DeviceCredentials device;
  final ConversationKey key;
  final FileEventStore sender;
  final FileEventStore receiver;
  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('zaizuo-relay-link-');
    final identity = await Identity.create('alice');
    final device = await DeviceCredentials.create();
    await device.authorize(identity, 'community');
    Future<FileEventStore> store(String name) async {
      final trust = TrustStore('community')..trustAccount(identity.public);
      await trust.authorizeDevice(device.certificate!);
      return FileEventStore.open(Directory('${root.path}/$name'), trust);
    }

    return _Fixture(
        root,
        identity,
        device,
        ConversationKey.generate('private-room', 1),
        await store('sender'),
        await store('receiver'));
  }

  Future<void> close() async {
    await sender.close();
    await receiver.close();
    await root.delete(recursive: true);
  }
}

Uri _url(int port) => Uri.parse('ws://127.0.0.1:$port/v1/ws');

Future<RelayLink> _connect(
  int port,
  FileEventStore store,
  Set<String> topics, {
  FutureOr<void> Function(EncryptedEvent)? onImported,
  bool autoReconnect = false,
  int maxPendingPublishes = 32,
  int maxPendingImports = 32,
  Duration requestTimeout = const Duration(seconds: 2),
}) =>
    RelayLink.connect(
        url: _url(port),
        token: _token,
        store: store,
        topics: topics,
        onImported: onImported,
        autoReconnect: autoReconnect,
        maxPendingPublishes: maxPendingPublishes,
        maxPendingImports: maxPendingImports,
        requestTimeout: requestTimeout,
        reconnectDelay: const Duration(milliseconds: 20));

Matcher _failure(String code) => isA<RelayLinkException>()
    .having((error) => error.code, 'code', code)
    .having((error) => error.requiresGit, 'requiresGit', isTrue);

void main() {
  late _Fixture fixture;
  late String topic;
  setUp(() async {
    fixture = await _Fixture.create();
    topic = await relayTopic(
        communityId: 'community', conversationId: fixture.key.conversationId);
  });
  tearDown(() => fixture.close());

  test('topic uses separated canonical fields, no key or clear room name',
      () async {
    expect(topic, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(topic, isNot(contains('private-room')));
    expect(await relayTopic(communityId: 'a:b', conversationId: 'c'),
        isNot(await relayTopic(communityId: 'a', conversationId: 'b:c')));
    expect(
        topic,
        await relayTopic(
            communityId: 'community', conversationId: 'private-room'));
  });

  test(
      'real relay delivers original ciphertext, receiver flushes and decrypts after reopen',
      () async {
    final relay = await RelayServer.start(RelayConfig(token: _token));
    addTearDown(relay.close);
    final imported = Completer<EncryptedEvent>();
    final receiver = await _connect(relay.port, fixture.receiver, {topic},
        onImported: (event) {
      imported.complete(event);
    });
    final sender = await _connect(relay.port, fixture.sender, {topic});
    addTearDown(receiver.close);
    addTearDown(sender.close);
    expect(receiver.isConnected, isTrue);
    final event = await fixture.sender.append(
        device: fixture.device,
        key: fixture.key,
        body: {'text': 'only encrypted envelope crosses relay'});
    final ack = await sender.publish(event).timeout(_guard);
    expect(ack.relayAccepted, isTrue);
    expect(ack.remoteDurable, isFalse);
    expect(ack.eventId, event.id);
    expect((await imported.future.timeout(_guard)).toJson(), event.toJson());
    expect(fixture.receiver.allEnvelopes.single.toJson(), event.toJson());
    await receiver.close();
    await fixture.receiver.close();
    final reopened = await FileEventStore.open(
        fixture.receiver.directory, fixture.receiver.trust);
    try {
      expect(reopened.allEnvelopes.single.toJson(), event.toJson());
      expect(await reopened.allEnvelopes.single.decrypt(fixture.key),
          {'text': 'only encrypted envelope crosses relay'});
    } finally {
      await reopened.close();
    }
  });

  test(
      'raw publisher invalid signature rejected by client, never written, next valid still imports',
      () async {
    final relay = await RelayServer.start(RelayConfig(token: _token));
    addTearDown(relay.close);
    final validImported = Completer<void>();
    final receiver =
        await _connect(relay.port, fixture.receiver, {topic}, onImported: (_) {
      validImported.complete();
    });
    addTearDown(receiver.close);
    final rejected =
        receiver.errors.firstWhere((error) => error.code == 'invalid_event');
    final socket = await WebSocket.connect(_url(relay.port).toString(),
        headers: {'Authorization': 'Bearer $_token'},
        compression: CompressionOptions.compressionOff);
    final input = StreamIterator<dynamic>(socket);
    addTearDown(() async {
      await socket.close();
      await input.cancel();
    });
    expect(await input.moveNext().timeout(_guard), isTrue);
    socket.add(
        jsonEncode({'op': 'subscribe', 'request_id': 's1', 'topic': topic}));
    expect(await input.moveNext().timeout(_guard), isTrue);
    final event = await fixture.sender.append(
        device: fixture.device, key: fixture.key, body: {'text': 'verified'});
    final tampered = event.toJson()
      ..['signature'] = base64Encode(List<int>.filled(64, 0));
    socket.add(jsonEncode({
      'op': 'publish',
      'request_id': 'bad',
      'topic': topic,
      'payload': base64Encode(utf8.encode(canonicalJson(tampered)))
    }));
    expect(
        await input.moveNext().timeout(_guard), isTrue); // dumb relay accepts
    expect((jsonDecode(input.current as String) as Map)['op'], 'ok');
    await rejected.timeout(_guard);
    expect(fixture.receiver.allEnvelopes, isEmpty);
    expect(await fixture.receiver.logFile.exists(), isFalse);
    final wrongRouteRejected =
        receiver.errors.firstWhere((error) => error.code == 'invalid_event');
    final otherRoute = await EncryptedEvent.create(
        communityId: 'community',
        device: fixture.device,
        key: ConversationKey.generate('other-room', 1),
        sequence: 1,
        clock: 1,
        previous: null,
        body: {'text': 'signed but wrong topic'});
    socket.add(jsonEncode({
      'op': 'publish',
      'request_id': 'wrong-route',
      'topic': topic,
      'payload': base64Encode(utf8.encode(canonicalJson(otherRoute.toJson())))
    }));
    expect(await input.moveNext().timeout(_guard), isTrue);
    await wrongRouteRejected.timeout(_guard);
    expect(fixture.receiver.allEnvelopes, isEmpty);
    socket.add(jsonEncode({
      'op': 'publish',
      'request_id': 'good',
      'topic': topic,
      'payload': base64Encode(utf8.encode(canonicalJson(event.toJson())))
    }));
    await validImported.future.timeout(_guard);
    expect(fixture.receiver.allEnvelopes.single.id, event.id);
  });

  test(
      'rejects events not durably in this store, wrong subscription and >32KiB envelopes',
      () async {
    final relay = await RelayServer.start(RelayConfig(token: _token));
    addTearDown(relay.close);
    final link = await _connect(relay.port, fixture.sender, {topic});
    addTearDown(link.close);
    final notPersisted = await EncryptedEvent.create(
        communityId: 'community',
        device: fixture.device,
        key: fixture.key,
        sequence: 1,
        clock: 1,
        previous: null,
        body: {'text': 'memory only'});
    await expectLater(
        link.publish(notPersisted), throwsA(_failure('not_persisted')));
    final large = await fixture.sender.append(
        device: fixture.device, key: fixture.key, body: {'text': 'x' * 30000});
    await expectLater(
        link.publish(large), throwsA(_failure('envelope_too_large')));
    final wrong = await fixture.sender.append(
        device: fixture.device,
        key: ConversationKey.generate('other-room', 1),
        body: {'text': 'other'});
    await expectLater(link.publish(wrong), throwsA(_failure('not_subscribed')));
    expect(fixture.receiver.allEnvelopes, isEmpty);
  });

  test('disconnect is explicit Git fallback, never a remote durability success',
      () async {
    final relay = await RelayServer.start(RelayConfig(token: _token));
    final link = await _connect(relay.port, fixture.sender, {topic});
    addTearDown(link.close);
    final disconnected =
        link.states.firstWhere((state) => state == RelayLinkState.disconnected);
    await relay.close();
    await disconnected.timeout(_guard);
    final event = await fixture.sender.append(
        device: fixture.device,
        key: fixture.key,
        body: {'text': 'Git fallback'});
    await expectLater(link.publish(event), throwsA(_failure('disconnected')));
    expect(fixture.sender.allEnvelopes.single.id, event.id);
    expect(fixture.receiver.allEnvelopes, isEmpty);
    await link.close();
    await expectLater(link.publish(event), throwsA(_failure('closed')));
  });

  test('auto reconnect resubscribes without replaying an uncertain old publish',
      () async {
    var relay = await RelayServer.start(RelayConfig(token: _token));
    final port = relay.port;
    final link =
        await _connect(port, fixture.receiver, {topic}, autoReconnect: true);
    addTearDown(link.close);
    final disconnected =
        link.states.firstWhere((state) => state == RelayLinkState.disconnected);
    await relay.close();
    await disconnected.timeout(_guard);
    final reconnected =
        link.states.firstWhere((state) => state == RelayLinkState.connected);
    relay = await RelayServer.start(RelayConfig(token: _token), port: port);
    addTearDown(relay.close);
    await reconnected.timeout(_guard);
    final imported = link.store.events.first;
    final sender = await _connect(port, fixture.sender, {topic});
    addTearDown(sender.close);
    final event = await fixture.sender.append(
        device: fixture.device,
        key: fixture.key,
        body: {'text': 'after reconnect'});
    await sender.publish(event);
    expect((await imported.timeout(_guard)).id, event.id);
    await link.close();
    expect(link.state, RelayLinkState.closed);
  });

  test(
      'duplicate original envelope is idempotent and close waits started import callback',
      () async {
    final relay = await RelayServer.start(RelayConfig(token: _token));
    addTearDown(relay.close);
    final started = Completer<void>();
    final release = Completer<void>();
    var calls = 0;
    final receiver = await _connect(relay.port, fixture.receiver, {topic},
        onImported: (_) async {
      calls++;
      if (!started.isCompleted) started.complete();
      await release.future;
    });
    final sender = await _connect(relay.port, fixture.sender, {topic});
    addTearDown(sender.close);
    addTearDown(receiver.close);
    final event = await fixture.sender
        .append(device: fixture.device, key: fixture.key, body: {'n': 1});
    await sender.publish(event);
    await started.future.timeout(_guard);
    await sender.publish(event);
    expect(fixture.receiver.allEnvelopes.length, 1);
    final closing = receiver.close();
    expect(identical(closing, receiver.close()), isTrue);
    release.complete();
    await closing.timeout(_guard);
    expect(calls, 1);
  });

  test('import queue is finite while host callback blocks', () async {
    final relay = await RelayServer.start(RelayConfig(token: _token));
    addTearDown(relay.close);
    final started = Completer<void>();
    final release = Completer<void>();
    final receiver = await _connect(relay.port, fixture.receiver, {topic},
        maxPendingImports: 1, onImported: (_) async {
      started.complete();
      await release.future;
    });
    final sender = await _connect(relay.port, fixture.sender, {topic});
    addTearDown(sender.close);
    addTearDown(receiver.close);
    final overflow = receiver.errors
        .firstWhere((error) => error.code == 'import_queue_full');
    final first = await fixture.sender
        .append(device: fixture.device, key: fixture.key, body: {'n': 1});
    await sender.publish(first);
    await started.future.timeout(_guard);
    final second = await fixture.sender
        .append(device: fixture.device, key: fixture.key, body: {'n': 2});
    await sender.publish(second);
    await overflow.timeout(_guard);
    expect(receiver.isConnected, isFalse);
    expect(fixture.receiver.allEnvelopes.map((event) => event.id), [first.id]);
    release.complete();
  });

  test(
      'loopback-only endpoints reject URL credentials/query/hostnames and WSS before dialing',
      () async {
    for (final url in [
      'ws://localhost:8787/v1/ws',
      'ws://192.0.2.1:8787/v1/ws',
      'wss://127.0.0.1:8787/v1/ws',
      'ws://127.0.0.1:8787/v1/ws?token=secret',
      'ws://name:pass@127.0.0.1:8787/v1/ws',
      'ws://127.0.0.1:8787/v1/ws#x',
    ]) {
      await expectLater(
          RelayLink.connect(
              url: Uri.parse(url),
              token: _token,
              store: fixture.sender,
              topics: {topic}),
          throwsA(_failure('unsupported_endpoint')));
    }
  });

  test('HTTP redirect never receives a forwarded Bearer on the target',
      () async {
    var targetRequests = 0;
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((request) async {
      targetRequests++;
      request.response.statusCode = 500;
      await request.response.close();
    });
    addTearDown(() => target.close(force: true));
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    source.listen((request) async {
      request.response
        ..statusCode = 302
        ..headers.set('Location', 'http://127.0.0.1:${target.port}/leak');
      await request.response.close();
    });
    addTearDown(() => source.close(force: true));
    await expectLater(_connect(source.port, fixture.sender, {topic}),
        throwsA(_failure('connect_failed')));
    expect(targetRequests, 0);
  });

  test(
      'connect waits for ready and subscribe acknowledgement before reporting connected',
      () async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => http.close(force: true));
    final subscribed = Completer<Map>();
    final acceptedSocket = Completer<WebSocket>();
    http.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request,
          compression: CompressionOptions.compressionOff);
      acceptedSocket.complete(ws);
      ws.add('{"op":"ready","version":1}');
      ws.listen((dynamic message) {
        final frame = jsonDecode(message as String) as Map;
        if (!subscribed.isCompleted) subscribed.complete(frame);
      });
    });
    var completed = false;
    final pending = _connect(http.port, fixture.sender, {topic}).then((link) {
      completed = true;
      return link;
    });
    final frame = await subscribed.future.timeout(_guard);
    expect(completed, isFalse);
    final socket = await acceptedSocket.future;
    socket.add(jsonEncode({
      'op': 'ok',
      'request_id': frame['request_id'],
      'for': 'subscribe',
      'topic': frame['topic']
    }));
    final link = await pending.timeout(_guard);
    expect(link.isConnected, isTrue);
    await link.close();
    await socket.close();
  });

  test('publish queue capacity includes inflight and ack timeout requires Git',
      () async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => http.close(force: true));
    final published = Completer<void>();
    final sockets = <WebSocket>[];
    http.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request,
          compression: CompressionOptions.compressionOff);
      sockets.add(ws);
      ws.add('{"op":"ready","version":1}');
      ws.listen((dynamic message) {
        final frame = jsonDecode(message as String) as Map;
        if (frame['op'] == 'subscribe') {
          ws.add(jsonEncode({
            'op': 'ok',
            'request_id': frame['request_id'],
            'for': 'subscribe',
            'topic': frame['topic']
          }));
        } else if (!published.isCompleted) {
          published.complete(); // deliberately no publish ack
        }
      });
    });
    addTearDown(() async {
      for (final ws in sockets) {
        await ws.close();
      }
    });
    final link = await _connect(http.port, fixture.sender, {topic},
        maxPendingPublishes: 1,
        requestTimeout: const Duration(milliseconds: 100));
    addTearDown(link.close);
    final event = await fixture.sender.append(
        device: fixture.device, key: fixture.key, body: {'text': 'pending'});
    final first = link.publish(event);
    final failed = expectLater(first, throwsA(_failure('ack_timeout')));
    await published.future.timeout(_guard);
    await expectLater(link.publish(event), throwsA(_failure('queue_full')));
    await failed;
    expect(link.isConnected, isFalse);
    expect(fixture.sender.allEnvelopes.single.id, event.id);
  });
}
