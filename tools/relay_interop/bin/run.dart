import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

const _guard = Duration(seconds: 8);
const _topicA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _topicB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
// These are plain byte fixtures, NOT encrypted/signed events or evidence of E2EE.
const _plainFixture = 'cGxhaW4taW50ZXJvcC1maXh0dXJlLW5vdC1lbmNyeXB0ZWQ=';

final class _Failure implements Exception {
  const _Failure(this.message);
  final String message;
  @override
  String toString() => message;
}

void _check(bool condition, String message) {
  if (!condition) throw _Failure(message);
}

bool _same(Object? actual, Object? expected) {
  if (actual is Map && expected is Map) {
    return actual.length == expected.length &&
        expected.keys.every((key) =>
            actual.containsKey(key) && _same(actual[key], expected[key]));
  }
  if (actual is List && expected is List) {
    return actual.length == expected.length &&
        List.generate(actual.length, (i) => _same(actual[i], expected[i]))
            .every((same) => same);
  }
  return actual == expected;
}

void _expect(Object? actual, Object? expected, String context) {
  // Do not dump arbitrary received data, payload or credentials on failure.
  _check(_same(actual, expected), '$context: response mismatch');
}

final class _Client {
  _Client._(this.socket) : messages = StreamIterator<dynamic>(socket);
  final WebSocket socket;
  final StreamIterator<dynamic> messages;

  static Future<_Client> connect(Uri base, String token) async {
    final socket = await WebSocket.connect(
      base.replace(scheme: 'ws', path: '/v1/ws').toString(),
      headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
      compression: CompressionOptions.compressionDefault,
    ).timeout(_guard);
    final client = _Client._(socket);
    try {
      _expect(await client.next(), {'op': 'ready', 'version': 1}, 'ready');
      _check(socket.extensions.isEmpty, 'compression must remain disabled');
      return client;
    } catch (_) {
      await client.dispose();
      rethrow;
    }
  }

  void raw(Object? request) => socket.add(jsonEncode(request));

  void send(String op, String id, String topic, [String? payload]) => raw({
        'op': op,
        'request_id': id,
        'topic': topic,
        if (payload != null) 'payload': payload,
      });

  Future<Map<String, dynamic>> next() async {
    _check(await messages.moveNext().timeout(_guard), 'connection ended early');
    final message = messages.current;
    _check(message is String, 'expected a text response');
    final decoded = jsonDecode(message as String);
    _check(decoded is Map<String, dynamic>, 'expected one JSON object');
    return decoded as Map<String, dynamic>;
  }

  Future<void> ok(String op, String id, String topic) async => _expect(
        await next(),
        {'op': 'ok', 'request_id': id, 'for': op, 'topic': topic},
        '$op acknowledgement',
      );

  Future<void> subscribe(String topic, String id) async {
    send('subscribe', id, topic);
    await ok('subscribe', id, topic);
  }

  Future<void> closed({int? code}) async {
    _check(!await messages.moveNext().timeout(_guard), 'expected a closed WS');
    if (code != null) {
      _check(socket.closeCode == code,
          'close code: expected $code got ${socket.closeCode}');
    }
  }

  Future<void> dispose() async {
    try {
      await socket.close().timeout(_guard);
    } catch (_) {
      // The child can already be killed by a restart scenario.
    } finally {
      await messages.cancel();
    }
  }
}

Future<(int, String)> _http(Uri base, String path,
    {String method = 'GET', Map<String, Object> headers = const {}}) async {
  final client = HttpClient()..connectionTimeout = _guard;
  try {
    final request =
        await client.openUrl(method, base.resolve(path)).timeout(_guard);
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(_guard);
    final body = await utf8.decoder.bind(response).join().timeout(_guard);
    return (response.statusCode, body);
  } finally {
    client.close(force: true);
  }
}

Map<String, Object> _upgradeHeaders(String? authorization) => {
      'Connection': 'Upgrade',
      'Upgrade': 'websocket',
      'Sec-WebSocket-Version': '13',
      'Sec-WebSocket-Key': 'AAECAwQFBgcICQoLDA0ODw==',
      if (authorization != null) HttpHeaders.authorizationHeader: authorization,
    };

Future<void> _auth(Uri endpoint, String token) async {
  _expect(await _http(endpoint, '/healthz'), (200, 'ok\n'), 'healthz');
  for (final authorization in <String?>[
    null,
    'Basic $token',
    'Bearer ${'x' * 40}',
    'Bearer short',
    'Bearer  $token',
  ]) {
    final (status, body) = await _http(endpoint, '/v1/ws',
        headers: _upgradeHeaders(authorization));
    _expect(status, 401, 'authorization gate');
    _check(!body.contains(token), 'credential appeared in HTTP response');
  }
  final repeated = _upgradeHeaders('Bearer $token')
    ..[HttpHeaders.authorizationHeader] = ['Bearer $token', 'Bearer $token'];
  _expect((await _http(endpoint, '/v1/ws', headers: repeated)).$1, 401,
      'duplicate authorization');
  for (final origin in ['', 'null', 'https://example.invalid']) {
    final headers = _upgradeHeaders(null)..['Origin'] = origin;
    _expect((await _http(endpoint, '/v1/ws', headers: headers)).$1, 403,
        'origin gate');
  }
  for (final path in ['/v1/ws?x=1', '/v1/ws?', '/healthz?']) {
    _expect(
        (await _http(endpoint, path, headers: _upgradeHeaders('Bearer $token')))
            .$1,
        400,
        'query gate');
  }
  _expect((await _http(endpoint, '/missing')).$1, 404, 'path gate');
  _expect(
      (await _http(endpoint, '/v1/ws', method: 'POST')).$1, 405, 'method gate');
}

Future<void> _vectors(Uri endpoint, String token, Directory root) async {
  final vectors = jsonDecode(
      await File.fromUri(root.uri.resolve('protocol/relay-v1-cases.json'))
          .readAsString()) as Map<String, dynamic>;
  _expect(vectors['version'], 1, 'vector version');
  final client = await _Client.connect(endpoint, token);
  try {
    var setup = 0;
    for (final raw in vectors['valid'] as List<dynamic>) {
      final request = raw as Map<String, dynamic>;
      if (request['op'] == 'publish') {
        await client.subscribe(request['topic'] as String, 'setup_${setup++}');
      }
      client.raw(request);
      await client.ok(request['op'] as String, request['request_id'] as String,
          request['topic'] as String);
    }
    for (final raw in vectors['invalid'] as List<dynamic>) {
      final invalid = raw as Map<String, dynamic>;
      final request = invalid['request'] as Map<String, dynamic>;
      final id = request['request_id'];
      final safeId =
          id is String && RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id);
      client.raw(request);
      _expect(
          await client.next(),
          {
            'op': 'error',
            if (safeId) 'request_id': id,
            'code': invalid['code'],
          },
          'shared invalid vector');
    }
  } finally {
    await client.dispose();
  }
}

Future<void> _routing(Uri endpoint, String token) async {
  final peers = <_Client>[];
  Future<_Client> connect() async {
    final client = await _Client.connect(endpoint, token);
    peers.add(client);
    return client;
  }

  try {
    final publisher = await connect();
    final receiver = await connect();
    final other = await connect();
    await publisher.subscribe(_topicA, 'sp');
    await receiver.subscribe(_topicA, 'sr');
    await other.subscribe(_topicB, 'so');
    publisher.send('publish', 'p1', _topicA, _plainFixture);
    // An accidental self-event precedes this ack and makes it fail.
    await publisher.ok('publish', 'p1', _topicA);
    _expect(await receiver.next(),
        {'op': 'event', 'topic': _topicA, 'payload': _plainFixture}, 'fanout');
    await other.subscribe(_topicB, 'other_barrier');
    // Bidirectional publishers use the same protocol, not separate client SDKs.
    receiver.send('publish', 'p2', _topicA, '/wABAg==');
    await receiver.ok('publish', 'p2', _topicA);
    _expect(
        await publisher.next(),
        {'op': 'event', 'topic': _topicA, 'payload': '/wABAg=='},
        'reverse fanout');
    receiver.send('unsubscribe', 'u1', _topicA);
    await receiver.ok('unsubscribe', 'u1', _topicA);
    receiver.send('unsubscribe', 'u2', _topicA);
    await receiver.ok('unsubscribe', 'u2', _topicA);
    publisher.send('publish', 'p3', _topicA, _plainFixture);
    await publisher.ok('publish', 'p3', _topicA);
    // Publisher ack is the causal barrier; no timeout/sleep is used to claim
    // absence of an event on unsubscribed or unrelated-topic connections.
    await receiver.subscribe(_topicB, 'unsubscribed_barrier');
    await other.subscribe(_topicB, 'other_barrier2');
    receiver.send('publish', 'not_subscribed', _topicA, _plainFixture);
    _expect(
        await receiver.next(),
        {
          'op': 'error',
          'request_id': 'not_subscribed',
          'code': 'not_subscribed',
        },
        'subscription resource gate');
  } finally {
    await Future.wait(peers.map((client) => client.dispose()));
  }
}

Future<void> _frameBoundaries(Uri endpoint, String token) async {
  final binary = await _Client.connect(endpoint, token);
  try {
    binary.socket.add([1, 2, 3]);
    await binary.closed(code: WebSocketStatus.unsupportedData);
  } finally {
    await binary.dispose();
  }
  final oversized = await _Client.connect(endpoint, token);
  try {
    oversized.socket.add('x' * 65537);
    await oversized.closed(code: WebSocketStatus.messageTooBig);
  } finally {
    await oversized.dispose();
  }
}

final class _Child {
  _Child._(this.process) {
    exited = process.exitCode.then((value) {
      exitStatus = value;
      return value;
    });
  }
  final Process process;
  late final Future<int> exited;
  int? exitStatus;
  bool _joined = false;

  static Future<_Child> start(String executable, List<String> args,
      Directory directory, Map<String, String> env) async {
    // inheritStdio avoids Windows named-pipe/stdout-capture sandbox boundaries.
    // The token is passed via environment, never as a command-line argument.
    final process = await Process.start(executable, args,
        workingDirectory: directory.path,
        environment: env,
        mode: ProcessStartMode.inheritStdio,
        runInShell: false);
    return _Child._(process);
  }

  Future<void> stop() async {
    if (_joined) return;
    try {
      if (exitStatus == null) process.kill(ProcessSignal.sigterm);
      try {
        await exited.timeout(_guard);
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await exited.timeout(_guard);
      }
      _joined = true;
    } catch (_) {
      throw const _Failure('child process could not be terminated and joined');
    }
  }
}

Future<int> _unusedLoopbackPort() async {
  final reservation = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  try {
    return reservation.port;
  } finally {
    await reservation.close();
  }
}

Future<void> _ready(_Child child, Uri endpoint) async {
  var backoff = const Duration(milliseconds: 20);
  // At most 15 attempts with exponential/capped backoff, each I/O bounded.
  // This is readiness waiting only, never a sleep-based message assertion.
  for (var attempt = 0; attempt < 15; attempt++) {
    if (child.exitStatus != null) {
      throw const _Failure('test endpoint exited before readiness');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 300);
    try {
      final request = await client
          .getUrl(endpoint.resolve('/healthz'))
          .timeout(const Duration(milliseconds: 300));
      final response =
          await request.close().timeout(const Duration(milliseconds: 300));
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(milliseconds: 300));
      if (response.statusCode == 200 && body == 'ok\n') return;
    } catch (_) {
      // Only health readiness is retried, never failed protocol assertions.
    } finally {
      client.close(force: true);
    }
    if (attempt < 14) await Future<void>.delayed(backoff);
    if (backoff.inMilliseconds < 1280) backoff *= 2;
  }
  throw const _Failure('bounded loopback health readiness deadline exceeded');
}

Future<void> _endpoint(
  String name,
  Future<_Child> Function(int port) launch,
  String token,
  Directory root,
) async {
  final port = await _unusedLoopbackPort();
  final endpoint = Uri.parse('http://127.0.0.1:$port');
  _Child? child;
  final peers = <_Client>[];
  try {
    child = await launch(port);
    await _ready(child, endpoint);
    await _auth(endpoint, token);
    await _vectors(endpoint, token, root);
    await _routing(endpoint, token);
    await _frameBoundaries(endpoint, token);
    stdout.writeln('PASS $name: auth / shared vectors / routing / frames');

    // Leave a live subscription and previously published bytes in generation 1.
    final oldPublisher = await _Client.connect(endpoint, token);
    peers.add(oldPublisher);
    await oldPublisher.subscribe(_topicA, 'old_s');
    oldPublisher.send('publish', 'old_p', _topicA, _plainFixture);
    await oldPublisher.ok('publish', 'old_p', _topicA);
    await child.stop();
    await oldPublisher.closed();

    // A new actual process, same port and token: no replay or subscriptions.
    child = await launch(port);
    await _ready(child, endpoint);
    final fresh = await _Client.connect(endpoint, token);
    peers.add(fresh);
    fresh.send('publish', 'fresh_not_subscribed', _topicA, _plainFixture);
    _expect(
        await fresh.next(),
        {
          'op': 'error',
          'request_id': 'fresh_not_subscribed',
          'code': 'not_subscribed',
        },
        'restart must lose subscription');
    await fresh.subscribe(_topicA, 'fresh_s');
    // This exact next ack detects any replay enqueued before a normal response.
    // No sleep, old bytes, persistence claim or cross-relay bridge is involved.
    await fresh.subscribe(_topicA, 'no_history_barrier');
    stdout.writeln('PASS $name: process restart / no subscription or replay');
  } on _Failure catch (failure) {
    throw _Failure('$name: ${failure.message}');
  } finally {
    // Stop children even if a protocol assertion fails. Stop first so blocked
    // client close handshakes cannot prevent process cleanup.
    try {
      await child?.stop();
    } finally {
      await Future.wait(peers.map((client) => client.dispose()));
    }
  }
}

Future<void> main(List<String> args) async {
  final tool = File.fromUri(Platform.script).parent.parent;
  final root = tool.parent.parent;
  final executableName =
      Platform.isWindows ? 'relay-interop.exe' : 'relay-interop';
  final binary = File.fromUri(root.uri.resolve('.local/bin/$executableName'));
  final dart = Platform.resolvedExecutable;
  final token = 'interop-test-only-${base64Url.encode(List<int>.generate(
    32,
    (_) => Random.secure().nextInt(256),
  ))}';
  final env = <String, String>{
    'ZAIZUO_RELAY_TOKEN': token,
    'PUB_CACHE': Directory.fromUri(root.uri.resolve('.local/pub-cache')).path,
    'TEMP': Directory.fromUri(root.uri.resolve('.local/temp')).path,
    'TMP': Directory.fromUri(root.uri.resolve('.local/temp')).path,
    'APPDATA': Directory.fromUri(root.uri.resolve('.local/dart-user')).path,
    'LOCALAPPDATA':
        Directory.fromUri(root.uri.resolve('.local/dart-user')).path,
    'DART_SUPPRESS_ANALYTICS': 'true',
  };
  try {
    _check(args.isEmpty, 'run.dart takes no command-line arguments');
    _check(await binary.exists(), 'build the Go relay with run.ps1 first');
    await _endpoint(
        'Go CLI',
        (port) => _Child.start(
            binary.path, ['-listen', '127.0.0.1:$port'], root, env),
        token,
        root);
    await _endpoint(
        'Dart RelayServer',
        (port) => _Child.start(
            dart, ['run', 'bin/dart_endpoint.dart', '$port'], tool, env),
        token,
        root);
    stdout.writeln(
        'PASS: same Dart native client accepted both relay-v1 endpoints.');
    stdout
        .writeln('No bridge, persistence or encryption capability was tested.');
  } on _Failure catch (failure) {
    stderr.writeln('FAIL: ${failure.message}');
    exitCode = 1;
  } catch (error) {
    // SDK network/process exceptions may contain URLs or headers; only type is
    // shown. The controlled failure labels above provide the assertion context.
    stderr.writeln(
        'FAIL: interop stopped (${error.runtimeType}); no input echoed.');
    exitCode = 1;
  }
}
