import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zaizuo_relay/zaizuo_relay.dart';

const _token = 'test-only-zaizuo-relay-token-000000000000';
const _a = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _b = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _c = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const _guard = Duration(seconds: 4);

final class _Client {
  _Client._(this.socket) : messages = StreamIterator<dynamic>(socket);

  final WebSocket socket;
  final StreamIterator<dynamic> messages;

  static Future<_Client> connect(RelayServer server,
      {String token = _token}) async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${server.port}/v1/ws',
      headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
      compression: CompressionOptions.compressionOff,
    ).timeout(_guard);
    final client = _Client._(socket);
    expect(await client.next(), {'op': 'ready', 'version': 1});
    return client;
  }

  void send(String op, String id, String topic, [String? payload]) =>
      socket.add(jsonEncode({
        'op': op,
        'request_id': id,
        'topic': topic,
        if (payload != null) 'payload': payload,
      }));

  Future<Map<String, dynamic>> next() async {
    expect(await messages.moveNext().timeout(_guard), isTrue,
        reason: 'expected response');
    expect(messages.current, isA<String>());
    return jsonDecode(messages.current as String) as Map<String, dynamic>;
  }

  Future<void> ok(String op, String id, String topic) async =>
      expect(await next(), {
        'op': 'ok',
        'request_id': id,
        'for': op,
        'topic': topic,
      });

  Future<void> subscribe(String topic, [String id = 's']) async {
    send('subscribe', id, topic);
    await ok('subscribe', id, topic);
  }

  Future<void> closed(int code) async {
    expect(await messages.moveNext().timeout(_guard), isFalse);
    expect(socket.closeCode, code);
  }

  Future<void> dispose() async {
    await socket.close().timeout(_guard);
    await messages.cancel();
  }
}

Future<(int, String, HttpHeaders)> _http(
  RelayServer server,
  String path, {
  String method = 'GET',
  Map<String, Object> headers = const {},
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
        method, Uri.parse('http://127.0.0.1:${server.port}$path'));
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(_guard);
    final body = await utf8.decoder.bind(response).join().timeout(_guard);
    return (response.statusCode, body, response.headers);
  } finally {
    client.close(force: true);
  }
}

Map<String, Object> _upgradeHeaders(
        {String? authorization = 'Bearer $_token', String? origin}) =>
    {
      'Connection': 'Upgrade',
      'Upgrade': 'websocket',
      'Sec-WebSocket-Version': '13',
      'Sec-WebSocket-Key': 'AAECAwQFBgcICQoLDA0ODw==',
      if (authorization != null) HttpHeaders.authorizationHeader: authorization,
      if (origin != null) 'Origin': origin,
    };

void main() {
  group('HTTP gate on loopback', () {
    late RelayServer server;
    setUp(() async {
      server = await RelayServer.start(RelayConfig(token: _token));
      expect(server.address.isLoopback, isTrue);
      expect(server.port, greaterThan(0));
    });
    tearDown(() => server.close());

    test('healthz is minimal and requires no credentials', () async {
      final (status, body, _) = await _http(server, '/healthz');
      expect(status, 200);
      expect(body, 'ok\n');
      expect(
          (await _http(server, '/healthz',
                  headers: {'Origin': 'https://example.invalid'}))
              .$1,
          200);
    });
    test('wrong paths, non-GET and any query are rejected', () async {
      expect((await _http(server, '/unknown')).$1, 404);
      expect((await _http(server, '/v1/ws/')).$1, 404);
      expect((await _http(server, '/v1/ws', method: 'POST')).$1, 405);
      expect((await _http(server, '/healthz', method: 'HEAD')).$1, 405);
      for (final path in ['/v1/ws?token=$_token', '/v1/ws?', '/healthz?x=1']) {
        final (status, body, _) =
            await _http(server, path, headers: _upgradeHeaders());
        expect(status, 400);
        expect(body, isNot(contains(_token)));
      }
    });
    test('missing, wrong and malformed Authorization are 401', () async {
      for (final authorization in <String?>[
        null,
        'Basic $_token',
        'Bearer ${'z' * 40}',
        'Bearer short',
        'Bearer  $_token',
        'Bearer ${'a' * 257}',
      ]) {
        final (status, body, headers) = await _http(server, '/v1/ws',
            headers: _upgradeHeaders(authorization: authorization));
        expect(status, 401);
        expect(body, isEmpty);
        expect(headers.value(HttpHeaders.wwwAuthenticateHeader), 'Bearer');
      }
    });
    test('duplicate Authorization rejected and Origin precedes auth', () async {
      final duplicate = _upgradeHeaders()
        ..[HttpHeaders.authorizationHeader] = [
          'Bearer $_token',
          'Bearer $_token'
        ];
      expect((await _http(server, '/v1/ws', headers: duplicate)).$1, 401);
      for (final origin in ['', 'null', 'https://example.invalid']) {
        final (status, body, _) = await _http(server, '/v1/ws',
            headers: _upgradeHeaders(authorization: null, origin: origin));
        expect(status, 403);
        expect(body, isEmpty);
      }
    });
    test('valid token without upgrade is bad request', () async {
      expect(
          (await _http(server, '/v1/ws',
                  headers: {HttpHeaders.authorizationHeader: 'Bearer $_token'}))
              .$1,
          400);
      final badKey = _upgradeHeaders()..['Sec-WebSocket-Key'] = 'AQID';
      expect((await _http(server, '/v1/ws', headers: badKey)).$1, 400);
    });
    test('repeated singleton upgrade headers fail with 400', () async {
      for (final header in [
        'Sec-WebSocket-Version',
        'Sec-WebSocket-Key',
        'Upgrade'
      ]) {
        final headers = _upgradeHeaders();
        headers[header] = [headers[header]!, headers[header]!];
        expect((await _http(server, '/v1/ws', headers: headers)).$1, 400);
      }
    });
    test('Bearer scheme is insensitive and compression is not negotiated',
        () async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${server.port}/v1/ws',
        headers: {HttpHeaders.authorizationHeader: 'bEaReR $_token'},
        compression: CompressionOptions.compressionDefault,
      );
      final input = StreamIterator<dynamic>(socket);
      expect(await input.moveNext().timeout(_guard), isTrue);
      expect(
          jsonDecode(input.current as String), {'op': 'ready', 'version': 1});
      expect(socket.extensions, isEmpty);
      await socket.close();
      await input.cancel();
    });
  });

  group('ordered subscription routing', () {
    late RelayServer server;
    final clients = <_Client>[];
    Future<_Client> connect() async {
      final client = await _Client.connect(server);
      clients.add(client);
      return client;
    }

    setUp(() async =>
        server = await RelayServer.start(RelayConfig(token: _token)));
    tearDown(() async {
      await Future.wait(clients.map((client) => client.dispose()));
      clients.clear();
      await server.close();
    });

    test('fanout excludes sender, isolates topics, and keeps opaque payload',
        () async {
      final sender = await connect();
      final receiver = await connect();
      final otherTopic = await connect();
      await sender.subscribe(_a);
      await receiver.subscribe(_a);
      await otherTopic.subscribe(_b);
      sender.send('publish', 'p1', _a, 'eyJub3QtYS1yZWxheS1maWVsZCI6dHJ1ZX0=');
      await sender.ok('publish', 'p1', _a);
      expect(await receiver.next(), {
        'op': 'event',
        'topic': _a,
        'payload': 'eyJub3QtYS1yZWxheS1maWVsZCI6dHJ1ZX0='
      });
      // Responses on each connection are barriers: no self/wrong-topic event
      // can precede the next response without making these comparisons fail.
      sender.send('subscribe', 'barrier', _a);
      await sender.ok('subscribe', 'barrier', _a);
      otherTopic.send('subscribe', 'barrier', _b);
      await otherTopic.ok('subscribe', 'barrier', _b);
      receiver.send('publish', 'p2', _a, '/wA=');
      await receiver.ok('publish', 'p2', _a);
      expect(
          await sender.next(), {'op': 'event', 'topic': _a, 'payload': '/wA='});
    });

    test('subscribe/unsubscribe idempotent and publish requires subscription',
        () async {
      final sender = await connect();
      final receiver = await connect();
      sender.send('publish', 'before', _a, 'AQID');
      expect(await sender.next(),
          {'op': 'error', 'request_id': 'before', 'code': 'not_subscribed'});
      await sender.subscribe(_a, 's1');
      await sender.subscribe(_a, 's2');
      await receiver.subscribe(_a);
      receiver.send('unsubscribe', 'u1', _a);
      await receiver.ok('unsubscribe', 'u1', _a);
      receiver.send('unsubscribe', 'u2', _a);
      await receiver.ok('unsubscribe', 'u2', _a);
      sender.send('publish', 'p1', _a, 'AQID');
      await sender.ok('publish', 'p1', _a); // no receivers still succeeds
      receiver.send('subscribe', 'barrier', _b);
      await receiver.ok('subscribe', 'barrier', _b);
      sender.send('unsubscribe', 'u3', _a);
      await sender.ok('unsubscribe', 'u3', _a);
      sender.send('publish', 'after', _a, 'AQID');
      expect(await sender.next(),
          {'op': 'error', 'request_id': 'after', 'code': 'not_subscribed'});
    });

    test('bad frames are safe errors and do not terminate a healthy connection',
        () async {
      final client = await connect();
      client.socket.add('{broken');
      expect(await client.next(), {'op': 'error', 'code': 'bad_request'});
      client.socket.add(jsonEncode(
          {'op': 'subscribe', 'request_id': 'sensitive text', 'topic': _a}));
      expect(await client.next(), {'op': 'error', 'code': 'bad_request'});
      client.socket.add(jsonEncode({'op': 'dance', 'request_id': 'safe'}));
      expect(await client.next(),
          {'op': 'error', 'request_id': 'safe', 'code': 'unsupported_op'});
      await client.subscribe(_a);
    });

    test('shared v1 vectors also run through native WebSocket I/O', () async {
      final vectors = jsonDecode(
              await File('../../protocol/relay-v1-cases.json').readAsString())
          as Map<String, dynamic>;
      final client = await connect();
      for (final value in vectors['valid'] as List) {
        final request = value as Map<String, dynamic>;
        if (request['op'] == 'publish') {
          await client.subscribe(request['topic'] as String, 'prepare');
        }
        client.socket.add(jsonEncode(request));
        await client.ok(request['op'] as String,
            request['request_id'] as String, request['topic'] as String);
      }
      for (final value in vectors['invalid'] as List) {
        final vector = value as Map<String, dynamic>;
        client.socket.add(jsonEncode(vector['request']));
        final response = await client.next();
        expect(response['op'], 'error');
        expect(response['code'], vector['code']);
        expect(response.keys, everyElement(isIn(['op', 'request_id', 'code'])));
      }
    });

    test('per-connection requests preserve input order', () async {
      final client = await connect();
      client.send('subscribe', 'one', _a);
      client.send('publish', 'two', _a, 'AQID');
      client.send('unsubscribe', 'three', _a);
      client.send('publish', 'four', _a, 'AQID');
      await client.ok('subscribe', 'one', _a);
      await client.ok('publish', 'two', _a);
      await client.ok('unsubscribe', 'three', _a);
      expect(await client.next(),
          {'op': 'error', 'request_id': 'four', 'code': 'not_subscribed'});
    });
  });

  group('resource limits and lifecycle', () {
    test('connection cap returns 503; stopping closes live WebSockets',
        () async {
      final server = await RelayServer.start(
          RelayConfig(token: _token, maxConnections: 1));
      addTearDown(server.close);
      final client = await _Client.connect(server);
      expect(
          (await _http(server, '/v1/ws', headers: _upgradeHeaders())).$1, 503);
      final closing = server.close();
      await client.closed(1001);
      await closing.timeout(_guard);
      await server.close();
      await client.dispose();
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      await expectLater(
          http.getUrl(Uri.parse('http://127.0.0.1:${server.port}/healthz')),
          throwsA(isA<SocketException>()));
    });

    test('topic cap is per connection and unsubscribe frees capacity',
        () async {
      final server = await RelayServer.start(
          RelayConfig(token: _token, maxTopicsPerConnection: 1));
      addTearDown(server.close);
      final client = await _Client.connect(server);
      addTearDown(client.dispose);
      await client.subscribe(_a, 's1');
      await client.subscribe(_a, 's2');
      client.send('subscribe', 'over', _b);
      expect(await client.next(),
          {'op': 'error', 'request_id': 'over', 'code': 'too_many_topics'});
      client.send('unsubscribe', 'u', _a);
      await client.ok('unsubscribe', 'u', _a);
      await client.subscribe(_b, 's3');
    });

    test('rate cap counts invalid requests and closes 1008', () async {
      final server = await RelayServer.start(
          RelayConfig(token: _token, maxRequestsPerWindow: 2));
      addTearDown(server.close);
      final client = await _Client.connect(server);
      addTearDown(client.dispose);
      client.socket.add('{}');
      expect((await client.next())['code'], 'bad_request');
      client.socket.add('[]');
      expect((await client.next())['code'], 'bad_request');
      client.send('subscribe', 'third', _a);
      await client.closed(1008);
    });

    test('binary always closes 1003 even if it encodes valid JSON', () async {
      final server = await RelayServer.start(RelayConfig(token: _token));
      addTearDown(server.close);
      final client = await _Client.connect(server);
      addTearDown(client.dispose);
      client.socket.add(utf8.encode(
          jsonEncode({'op': 'subscribe', 'request_id': 's', 'topic': _a})));
      await client.closed(1003);
    });

    test('message limit counts UTF-8 bytes, not Dart string length', () async {
      final server = await RelayServer.start(
          RelayConfig(token: _token, maxMessageBytes: 8));
      addTearDown(server.close);
      final client = await _Client.connect(server);
      addTearDown(client.dispose);
      client.socket.add('中' * 3); // 3 UTF-16 units, 9 UTF-8 bytes
      await client.closed(1009);
    });

    test('ASCII oversized complete message closes 1009', () async {
      final server = await RelayServer.start(
          RelayConfig(token: _token, maxMessageBytes: 100));
      addTearDown(server.close);
      final client = await _Client.connect(server);
      addTearDown(client.dispose);
      client.socket.add('x' * 101);
      await client.closed(1009);
    });

    test('payload decoded limit is checked before routing', () async {
      final server = await RelayServer.start(
          RelayConfig(token: _token, maxPayloadBytes: 1));
      addTearDown(server.close);
      final client = await _Client.connect(server);
      addTearDown(client.dispose);
      await client.subscribe(_a);
      client.send('publish', 'p1', _a, 'AQI=');
      expect(await client.next(),
          {'op': 'error', 'request_id': 'p1', 'code': 'bad_request'});
      client.send('publish', 'p2', _a, 'AQ==');
      await client.ok('publish', 'p2', _a);
    });

    test('close is idempotent and can close multiple active topics', () async {
      final server = await RelayServer.start(RelayConfig(token: _token));
      final clients =
          await Future.wait(List.generate(3, (_) => _Client.connect(server)));
      for (final (index, client) in clients.indexed) {
        await client.subscribe([_a, _b, _c][index]);
      }
      final closing = server.close();
      expect(identical(closing, server.close()), isTrue);
      await Future.wait(clients.map((client) => client.closed(1001)));
      await closing.timeout(_guard);
      await Future.wait(clients.map((client) => client.dispose()));
    });
  });
}
