import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'config.dart';
import 'outbox.dart';
import 'protocol.dart';
import 'rate_window.dart';
import 'transport.dart';

/// 可嵌入 Flutter Native 生命周期的纯 Dart 中继，无 Flutter 或框架依赖。
///
/// 默认只监听 IPv4 环回。跨主机时由宿主明确提供地址并部署 TLS/WSS 或
/// 可信加密组网。本类不输出日志，也不解析 payload 中的业务字段。
final class RelayServer {
  RelayServer._(this._http, this._config)
      : port = _http.port,
        address = _http.address {
    final random = Random.secure();
    final key = List<int>.generate(32, (_) => random.nextInt(256));
    _authMac = Hmac(sha256, key);
    _expectedDigest = _authMac.convert(ascii.encode(_config.token)).bytes;
    _subscription = _http.listen(
      (request) {
        final operation = _handle(request);
        _requests.add(operation);
        unawaited(operation.whenComplete(() => _requests.remove(operation)));
      },
      onError: (Object _, StackTrace __) {
        // Network errors are deliberately not logged. Lifecycle owner can close.
      },
    );
  }

  /// 绑定端口并启动服务。port=0 由操作系统选择端口，可通过 [port] 获取。
  static Future<RelayServer> start(
    RelayConfig config, {
    InternetAddress? address,
    int port = 0,
  }) async {
    if (port < 0 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'must be between 0 and 65535');
    }
    final http =
        await HttpServer.bind(address ?? InternetAddress.loopbackIPv4, port);
    http
      ..serverHeader = null
      ..idleTimeout = config.writeTimeout;
    return RelayServer._(http, config);
  }

  final HttpServer _http;
  final RelayConfig _config;
  late final Hmac _authMac;
  late final List<int> _expectedDigest;
  late final StreamSubscription<HttpRequest> _subscription;
  final Set<_Peer> _peers = {};
  final Map<String, Set<_Peer>> _topics = {};
  final Set<Future<void>> _requests = {};
  int _upgrading = 0;
  bool _stopping = false;
  Future<void>? _closing;

  final int port;
  final InternetAddress address;

  /// 幂等停止：先停止接入，再关闭所有 WS（不是仅关闭 HTTP 监听）。
  ///
  /// 在配置的写入/关闭宽限后强制销毁底层 socket。内存订阅全部丢弃。
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _stopping = true;
    final stopHttp = _http.close(force: true);
    await Future.wait<void>([
      for (final peer in _peers.toList()) peer.close(WebSocketStatus.goingAway),
      stopHttp.then<void>((_) {}),
    ]);
    // In-flight upgrades have a timeout and destroy any socket arriving late.
    await Future.wait<void>(_requests.toList());
    await _subscription.cancel();
    _topics.clear();
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.uri.path != '/v1/ws' && request.uri.path != '/healthz') {
        await _respond(request, HttpStatus.notFound);
        return;
      }
      if (request.method != 'GET') {
        request.response.headers.set(HttpHeaders.allowHeader, 'GET');
        await _respond(request, HttpStatus.methodNotAllowed);
        return;
      }
      if (request.uri.hasQuery) {
        await _respond(request, HttpStatus.badRequest);
        return;
      }
      if (request.uri.path == '/healthz') {
        await _respond(request, HttpStatus.ok, 'ok\n');
        return;
      }
      if (request.headers['origin'] != null) {
        await _respond(request, HttpStatus.forbidden);
        return;
      }
      if (!_authorized(request)) {
        request.response.headers
            .set(HttpHeaders.wwwAuthenticateHeader, 'Bearer');
        await _respond(request, HttpStatus.unauthorized);
        return;
      }
      if (!_validUpgrade(request)) {
        await _respond(request, HttpStatus.badRequest);
        return;
      }
      if (_stopping || _peers.length + _upgrading >= _config.maxConnections) {
        await _respond(request, HttpStatus.serviceUnavailable);
        return;
      }
      // Reserve before awaiting upgrade, preventing concurrent admission races.
      _upgrading++;
      try {
        final transport = await _upgrade(request);
        if (_stopping) {
          transport.inputDone();
          await transport.close(WebSocketStatus.goingAway);
          return;
        }
        final peer = _Peer(this, transport);
        _peers.add(peer);
        peer.start();
      } finally {
        _upgrading--;
      }
    } catch (_) {
      // No arbitrary input, request URI, payload or credential is logged.
      // detach/response failures need not create another HTTP response.
      try {
        await request.response.close().timeout(_config.writeTimeout);
      } catch (_) {}
    }
  }

  bool _authorized(HttpRequest request) {
    final values = request.headers[HttpHeaders.authorizationHeader];
    if (values == null || values.length != 1) return false;
    final value = values.single;
    if (value.length < 7 || value.substring(0, 7).toLowerCase() != 'bearer ') {
      return false;
    }
    final token = value.substring(7);
    if (!isValidRelayToken(token)) return false;
    final digest = _authMac.convert(ascii.encode(token)).bytes;
    var difference = 0;
    // Both values are always 32 bytes derived using the same random local key.
    // No token-character comparison or digest early-exit is used.
    for (var i = 0; i < _expectedDigest.length; i++) {
      difference |= digest[i] ^ _expectedDigest[i];
    }
    return difference == 0;
  }

  bool _validUpgrade(HttpRequest request) {
    try {
      return WebSocketTransformer.isUpgradeRequest(request) &&
          _validKey(request);
    } on HttpException {
      // HttpHeaders.value throws on repeated singleton handshake headers.
      return false;
    }
  }

  bool _validKey(HttpRequest request) {
    final keys = request.headers['sec-websocket-key'];
    if (keys == null || keys.length != 1) return false;
    try {
      final bytes = base64Decode(keys.single);
      return bytes.length == 16 && base64Encode(bytes) == keys.single;
    } on FormatException {
      return false;
    }
  }

  Future<RelayTransport> _upgrade(HttpRequest request) async {
    // The public transformer hides the Socket needed for flush and forced
    // shutdown. Perform only the standard HTTP handshake here; the SDK owns
    // all WebSocket data framing via WebSocket.fromUpgradedSocket.
    final response = request.response;
    final key = request.headers['sec-websocket-key']!.single;
    final accept = base64Encode(
      sha1
          .convert(ascii.encode('$key' '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))
          .bytes,
    );
    response
      ..statusCode = HttpStatus.switchingProtocols
      ..contentLength = 0;
    response.headers
      ..set(HttpHeaders.connectionHeader, 'Upgrade')
      ..set(HttpHeaders.upgradeHeader, 'websocket')
      ..set('Sec-WebSocket-Accept', accept);
    // No Sec-WebSocket-Extensions is returned: compression is never enabled.
    var expired = false;
    final detached = response.detachSocket().then((socket) {
      if (expired || _stopping) {
        socket.destroy();
        throw const SocketException.closed();
      }
      return socket;
    });
    final socket = await detached.timeout(_config.writeTimeout, onTimeout: () {
      expired = true;
      throw TimeoutException('WebSocket upgrade timed out');
    });
    socket.setOption(SocketOption.tcpNoDelay, true);
    return RelayTransport(socket, _config.writeTimeout);
  }

  Future<void> _respond(HttpRequest request, int status,
      [String body = '']) async {
    request.response
      ..statusCode = status
      ..persistentConnection = false
      ..headers.contentType = ContentType.text
      ..contentLength = utf8.encode(body).length
      ..write(body);
    await request.response.close().timeout(_config.writeTimeout);
  }

  void _remove(_Peer peer) {
    // Keep closing sockets in _peers until transport teardown finishes so they
    // still count against admission and close() joins their lifetime.
    for (final topic in peer.topics) {
      final subscribers = _topics[topic];
      subscribers?.remove(peer);
      if (subscribers != null && subscribers.isEmpty) _topics.remove(topic);
    }
    peer.topics.clear();
  }

  void _request(_Peer peer, RelayRequest request) {
    switch (request.op) {
      case 'subscribe':
        if (!peer.topics.contains(request.topic)) {
          if (peer.topics.length >= _config.maxTopicsPerConnection) {
            peer.error('too_many_topics', request.requestId);
            return;
          }
          peer.topics.add(request.topic);
          (_topics[request.topic] ??= {}).add(peer);
        }
      case 'unsubscribe':
        peer.topics.remove(request.topic);
        final subscribers = _topics[request.topic];
        subscribers?.remove(peer);
        if (subscribers != null && subscribers.isEmpty) {
          _topics.remove(request.topic);
        }
      case 'publish':
        if (!peer.topics.contains(request.topic)) {
          peer.error('not_subscribed', request.requestId);
          return;
        }
        final event = jsonEncode({
          'op': 'event',
          'topic': request.topic,
          'payload': request.payload!,
        });
        // enqueue may close/remove slow receivers; snapshot avoids mutation.
        for (final receiver in (_topics[request.topic] ?? {}).toList()) {
          if (!identical(receiver, peer)) receiver.send(event);
        }
    }
    peer.send(jsonEncode({
      'op': 'ok',
      'request_id': request.requestId,
      'for': request.op,
      'topic': request.topic,
    }));
  }
}

final class _Peer {
  _Peer(this.server, this.transport) {
    outbox = BoundedOutbox(
      capacity: server._config.maxPendingMessages,
      timeout: server._config.writeTimeout,
      write: transport.write,
      onBackpressure: () => unawaited(close(1013)),
    );
    transport.onWriteFailure = () => unawaited(close(1013));
  }

  final RelayServer server;
  final RelayTransport transport;
  final Set<String> topics = {};
  late final BoundedOutbox outbox;
  late final RequestWindow window =
      RequestWindow(server._config.maxRequestsPerWindow);
  final Stopwatch _clock = Stopwatch()..start();
  Future<void>? _closing;

  void start() {
    transport.webSocket
      ..pingInterval = server._config.pingInterval
      ..listen(
        receive,
        onError: (Object _, StackTrace __) {
          transport.inputDone();
          unawaited(close(WebSocketStatus.protocolError));
        },
        onDone: () {
          transport.inputDone();
          unawaited(close(WebSocketStatus.normalClosure));
        },
        cancelOnError: true,
      );
    send('{"op":"ready","version":1}');
  }

  void send(String message) {
    if (_closing == null) outbox.add(message);
  }

  void error(String code, [String? requestId]) => send(jsonEncode({
        'op': 'error',
        if (requestId != null) 'request_id': requestId,
        'code': code,
      }));

  void receive(dynamic message) {
    if (_closing != null) return;
    if (message is! String) {
      unawaited(close(WebSocketStatus.unsupportedData));
      return;
    }
    // A UTF-16 code-unit count is a lower bound on UTF-8 length and cheaply
    // rejects huge already-assembled strings before an extra encoding copy.
    if (message.length > server._config.maxMessageBytes ||
        utf8.encode(message).length > server._config.maxMessageBytes) {
      unawaited(close(WebSocketStatus.messageTooBig));
      return;
    }
    if (!window.accept(_clock.elapsedMicroseconds)) {
      unawaited(close(WebSocketStatus.policyViolation));
      return;
    }
    switch (parseRequest(message,
        maxPayloadBytes: server._config.maxPayloadBytes)) {
      case RequestFailure(:final code, :final requestId):
        error(code, requestId);
      case RelayRequest request:
        server._request(this, request);
    }
  }

  Future<void> close(int code) => _closing ??= _close(code);

  Future<void> _close(int code) async {
    _clock.stop();
    outbox.stop();
    server._remove(this);
    try {
      await transport.close(code);
    } finally {
      server._peers.remove(this);
    }
  }
}
