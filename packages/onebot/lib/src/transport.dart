import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'backend.dart';
import 'guarded_socket.dart';
import 'projection.dart';

void validateLocalToken(String token) {
  if (token.length < 32 ||
      token.length > 256 ||
      token.codeUnits.any((value) => value < 0x21 || value > 0x7e)) {
    throw ArgumentError('Token must have 32..256 printable ASCII characters');
  }
}

// 固定最大 token 宽度遍历，不对第一个不同字符提前返回；不声称编译器级常时审计。
bool _equalToken(String left, String right) {
  var diff = left.length ^ right.length;
  for (var i = 0; i < 256; i++) {
    diff |= (i < left.length ? left.codeUnitAt(i) : 0) ^
        (i < right.length ? right.codeUnitAt(i) : 0);
  }
  return diff == 0;
}

class OneBotBinding {
  OneBotBinding({required this.token, required this.projection}) {
    validateLocalToken(token);
  }
  final String token;
  final OneBotProjection projection;
}

class OneBotLimits {
  const OneBotLimits(
      {this.maxConnections = 64,
      this.maxHttpRequests = 32,
      this.maxHeaderBytes = 16384,
      this.maxBodyBytes = 65536,
      this.maxIncomingQueue = 16,
      this.maxOutgoingQueue = 32,
      this.requestsPerWindow = 100,
      this.requestWindow = const Duration(seconds: 10),
      this.headerTimeout = const Duration(seconds: 5),
      this.bodyTimeout = const Duration(seconds: 5),
      this.actionTimeout = const Duration(seconds: 35),
      this.writeTimeout = const Duration(seconds: 5),
      this.pingInterval = const Duration(seconds: 30)});

  /// 显式启用单文件base64传输；默认构造仍是64KiB，不隐式扩大。
  factory OneBotLimits.media(
      {int maxMediaBytes = 8 * 1024 * 1024,
      int maxConnections = 8,
      int maxHttpRequests = 2}) {
    if (maxMediaBytes < 1) throw ArgumentError('Media size must be positive');
    final wire = ((maxMediaBytes + 2) ~/ 3) * 4 + 65536;
    return OneBotLimits(
        maxBodyBytes: wire,
        maxConnections: maxConnections,
        maxHttpRequests: maxHttpRequests,
        maxIncomingQueue: 2,
        maxOutgoingQueue: 2);
  }
  final int maxConnections;
  final int maxHttpRequests;
  final int maxHeaderBytes;
  final int maxBodyBytes;
  final int maxIncomingQueue;
  final int maxOutgoingQueue;
  final int requestsPerWindow;
  final Duration requestWindow;
  final Duration headerTimeout;
  final Duration bodyTimeout;
  final Duration actionTimeout;
  final Duration writeTimeout;
  final Duration pingInterval;
  void validate() {
    for (final value in [
      maxConnections,
      maxHttpRequests,
      maxHeaderBytes,
      maxBodyBytes,
      maxIncomingQueue,
      maxOutgoingQueue,
      requestsPerWindow
    ]) {
      if (value < 1) throw ArgumentError('Limits must be positive');
    }
    for (final value in [
      requestWindow,
      headerTimeout,
      bodyTimeout,
      actionTimeout,
      writeTimeout,
      pingInterval
    ]) {
      if (value <= Duration.zero)
        throw ArgumentError('Timeouts must be positive');
    }
  }
}

/// 本机 JSON/UTF-8 HTTP POST + 正向 WS。不存在任意 URL 抓取入口。
/// 监听地址只接受环回 IP，跨主机使用反向 WS 的显式 WSS allowlist。
class OneBotServer {
  OneBotServer(
      {required List<OneBotBinding> bindings,
      this.limits = const OneBotLimits()})
      : bindings = List.unmodifiable(bindings) {
    limits.validate();
    if (bindings.isEmpty ||
        bindings.map((value) => value.token).toSet().length !=
            bindings.length) {
      throw ArgumentError('Each bot binding requires a unique token');
    }
  }
  final List<OneBotBinding> bindings;
  final OneBotLimits limits;
  HttpServer? _server;
  GuardedServerSocket? _listener;
  final Set<OneBotWsPeer> _peers = {};
  bool _closed = false;
  int _requests = 0;
  int get port => _server?.port ?? (throw StateError('Not listening'));

  Future<void> start({InternetAddress? address, int port = 0}) async {
    if (_server != null || _closed)
      throw StateError('Server already started/closed');
    final bindAddress = address ?? InternetAddress.loopbackIPv4;
    if (!bindAddress.isLoopback)
      throw ArgumentError('Only loopback listeners are supported');
    final socket = await ServerSocket.bind(bindAddress, port,
        backlog: limits.maxConnections);
    final listener = GuardedServerSocket(socket,
        maxHeaderBytes: limits.maxHeaderBytes,
        headerTimeout: limits.headerTimeout,
        maxConnections: limits.maxConnections,
        maxMessageBytes: limits.maxBodyBytes,
        bodyTimeout: limits.bodyTimeout);
    _listener = listener;
    final server = HttpServer.listenOn(listener)
      ..idleTimeout = limits.headerTimeout
      ..serverHeader = null
      ..autoCompress = false;
    _server = server;
    server.listen((request) {
      unawaited(_handle(request));
    }, onError: (Object _) {});
  }

  OneBotBinding? _authenticate(HttpRequest request) {
    final values = request.headers[HttpHeaders.authorizationHeader];
    if (values == null ||
        values.length != 1 ||
        !values.single.startsWith('Bearer ')) return null;
    final supplied = values.single.substring(7);
    if (supplied.length > 256) return null;
    OneBotBinding? found;
    for (final binding in bindings) {
      if (_equalToken(supplied, binding.token)) found = binding;
    }
    return found;
  }

  Future<void> _handle(HttpRequest request) async {
    request.response.persistentConnection = false;
    request.response.headers.set('X-Content-Type-Options', 'nosniff');
    try {
      if (_closed) {
        await _httpError(request, 503);
        return;
      }
      if (request.headers['origin'] != null) {
        await _httpError(request, 403);
        return;
      }
      // URL 上任何查询参数都拒绝，包括 access_token；不在日志中回显 URL。
      if (request.uri.hasQuery ||
          request.uri.hasFragment ||
          request.uri.userInfo.isNotEmpty) {
        await _httpError(request, 400);
        return;
      }
      final segments = request.uri.pathSegments;
      if (segments.length < 2 ||
          segments.length > 3 ||
          segments[0] != 'onebot' ||
          (segments[1] != 'v11' && segments[1] != 'v12') ||
          (segments[1] == 'v12' && segments.length != 2)) {
        await _httpError(request, 404);
        return;
      }
      final version = segments[1] == 'v11' ? 11 : 12;
      final binding = _authenticate(request);
      if (binding == null) {
        await _httpError(request, 401);
        return;
      }
      if (binding.projection.ids.persistenceFailed) {
        await _httpError(request, 503);
        return;
      }
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        if (request.method != 'GET' || segments.length != 2) {
          await _httpError(request, 405);
          return;
        }
        if (_peers.length >= limits.maxConnections) {
          await _httpError(request, 503);
          return;
        }
        final ws = await WebSocketTransformer.upgrade(request,
            compression: CompressionOptions.compressionOff);
        if (_closed) {
          await ws.close(WebSocketStatus.goingAway);
          return;
        }
        late final OneBotWsPeer peer;
        peer = OneBotWsPeer(ws, binding.projection, version, limits,
            onClosed: () => _peers.remove(peer));
        _peers.add(peer);
        return;
      }
      if (request.method != 'POST') {
        await _httpError(request, 405);
        return;
      }
      if (request.headers.contentType?.mimeType != 'application/json') {
        await _httpError(request, version == 11 ? 406 : 415);
        return;
      }
      if (_requests >= limits.maxHttpRequests) {
        await _httpError(request, 503);
        return;
      }
      _requests++;
      try {
        Object? body;
        try {
          body = jsonDecode(utf8.decode(await _readBody(request)));
        } catch (_) {
          if (version == 11) {
            await _httpError(request, 400);
            return;
          }
          await _json(
              request,
              binding.projection.failure(
                  12,
                  const OneBotFailure(
                      'bad_request', 'Invalid JSON request body')));
          return;
        }
        _bodyComplete(request);
        Object? action = body;
        if (version == 11 && segments.length == 3) {
          if (body is! Map<String, dynamic>) {
            await _httpError(request, 400);
            return;
          }
          final params = Map<String, dynamic>.from(body)..remove('echo');
          action = {
            'action': segments[2],
            'params': params,
            if (body.containsKey('echo')) 'echo': body['echo']
          };
        }
        final response = await binding.projection
            .handle(version, action)
            .timeout(limits.actionTimeout,
                onTimeout: () => binding.projection.failure(
                    version,
                    const OneBotFailure('unavailable',
                        'Action timed out; outcome may be unknown')));
        if (version == 11 && response['zaizuo.code'] == 'unsupported_action') {
          request.response.statusCode = 404;
        }
        await _json(request, response);
      } finally {
        _requests--;
      }
    } catch (_) {
      // 不向客户端/日志泄露 request、Authorization、异常 URL 或内部数据。
      try {
        await _httpError(request, 500);
      } catch (_) {}
    }
  }

  void _bodyComplete(HttpRequest request) {
    final info = request.connectionInfo;
    if (info == null) return;
    for (final socket in _listener?.sockets ?? <GuardedSocket>{}) {
      if (socket.remotePort == info.remotePort &&
          socket.remoteAddress.address == info.remoteAddress.address) {
        socket.httpBodyComplete();
        return;
      }
    }
  }

  Future<List<int>> _readBody(HttpRequest request) async {
    if (request.contentLength > limits.maxBodyBytes)
      throw const FormatException('Body too large');
    final bytes = <int>[];
    // timeout 是整个正文到达期限，而非每个字节刷新，限制慢速正文。
    return (() async {
      await for (final chunk in request) {
        if (bytes.length + chunk.length > limits.maxBodyBytes) {
          throw const FormatException('Body too large');
        }
        bytes.addAll(chunk);
      }
      return bytes;
    })()
        .timeout(limits.bodyTimeout);
  }

  Future<void> _json(HttpRequest request, Map<String, dynamic> body) async {
    request.response.headers.contentType = ContentType.json;
    final encoded = jsonEncode(body);
    if (utf8.encode(encoded).length > limits.maxBodyBytes) {
      request.response.write(jsonEncode({
        'status': 'failed',
        'retcode': 35003,
        'data': null,
        'message': 'Response exceeds configured transport limit',
        'zaizuo.code': 'quota_exceeded'
      }));
    } else {
      request.response.write(encoded);
    }
    await request.response.close().timeout(limits.writeTimeout);
  }

  Future<void> _httpError(HttpRequest request, int status) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.text;
    request.response.write('OneBot request rejected\n');
    await request.response.close().timeout(limits.writeTimeout);
  }

  Future<void> close({bool closeProjections = false}) async {
    if (_closed) return;
    _closed = true;
    await Future.wait(
        _peers.toList().map((peer) => peer.close(WebSocketStatus.goingAway)));
    await _server?.close(force: true);
    _listener?.destroyAll();
    await _listener?.close();
    if (closeProjections) {
      for (final projection
          in bindings.map((value) => value.projection).toSet()) {
        await projection.close();
      }
    }
  }
}

/// WebSocket 应用层队列独立受限。慢连接不阻塞其它客户端。
class OneBotWsPeer {
  OneBotWsPeer(this.socket, this.projection, this.version, this.limits,
      {required this.onClosed}) {
    socket.pingInterval = limits.pingInterval;
    _eventSubscription =
        projection.events.listen((event) => enqueue(event.forVersion(version)));
    _inputSubscription =
        socket.listen(_input, onDone: _done, onError: (Object _) => _done());
    _initialEvents();
    if (version == 12) {
      _statusTimer = Timer.periodic(limits.pingInterval, (_) {
        unawaited(_statusUpdate());
      });
    }
  }
  final WebSocket socket;
  final OneBotProjection projection;
  final int version;
  final OneBotLimits limits;
  final void Function() onClosed;
  final _incoming = Queue<Object?>();
  final _outgoing = Queue<String>();
  late final StreamSubscription<OneBotEvent> _eventSubscription;
  late final StreamSubscription<dynamic> _inputSubscription;
  bool _reading = false;
  bool _writing = false;
  Future<void>? _writingTask;
  bool _closed = false;
  DateTime _window = DateTime.now();
  int _windowRequests = 0;
  final _finished = Completer<void>();
  Timer? _statusTimer;
  String? _lastStatus;
  bool _statusUpdating = false;
  Future<void> get done => _finished.future;

  Map<String, dynamic> _meta(String detail) => {
        'id':
            'zaizuo.meta:${base64Url.encode(List<int>.generate(18, (_) => Random.secure().nextInt(256)))}',
        'time': DateTime.now().toUtc().millisecondsSinceEpoch / 1000,
        'type': 'meta',
        'detail_type': detail,
        'sub_type': '',
      };
  void _initialEvents() {
    if (version == 11) {
      enqueue({
        'time': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
        'self_id': projection.ids.encode('user', projection.backend.botId),
        'post_type': 'meta_event',
        'meta_event_type': 'lifecycle',
        'sub_type': 'connect'
      });
    } else {
      enqueue(_meta('connect')
        ..['version'] = {
          'impl': oneBotImplementation,
          'version': oneBotImplementationVersion,
          'onebot_version': '12',
          'zaizuo.compatibility': 'subset',
        });
      unawaited(_statusUpdate());
    }
  }

  Future<void> _statusUpdate() async {
    if (_closed || _statusUpdating) return;
    _statusUpdating = true;
    try {
      final status =
          await projection.handle(12, {'action': 'get_status', 'params': {}});
      final data = status['data'];
      if (status['status'] != 'ok') return;
      final encoded = jsonEncode(data);
      if (encoded != _lastStatus) {
        _lastStatus = encoded;
        enqueue(_meta('status_update')..['status'] = data);
      }
    } finally {
      _statusUpdating = false;
    }
  }

  void _input(Object? frame) {
    if (_closed) return;
    final now = DateTime.now();
    if (now.difference(_window) >= limits.requestWindow) {
      _window = now;
      _windowRequests = 0;
    }
    if (++_windowRequests > limits.requestsPerWindow) {
      unawaited(close(WebSocketStatus.policyViolation));
      return;
    }
    if (frame is! String) {
      enqueue(projection.failure(
          version,
          const OneBotFailure(
              'bad_request', 'Binary/MessagePack is not supported')));
      return;
    }
    if (utf8.encode(frame).length > limits.maxBodyBytes) {
      unawaited(close(WebSocketStatus.messageTooBig));
      return;
    }
    if (_incoming.length + (_reading ? 1 : 0) >= limits.maxIncomingQueue) {
      unawaited(close(3013));
      return;
    }
    Object? value;
    try {
      value = jsonDecode(frame);
    } catch (_) {
      value = null;
    }
    _incoming.add(value);
    if (!_reading) unawaited(_drainIncoming());
  }

  Future<void> _drainIncoming() async {
    _reading = true;
    try {
      while (!_closed && _incoming.isNotEmpty) {
        final request = _incoming.removeFirst();
        final response = await projection.handle(version, request).timeout(
            limits.actionTimeout,
            onTimeout: () => projection.failure(
                version,
                const OneBotFailure('unavailable',
                    'Action timed out; outcome may be unknown')));
        enqueue(response);
      }
    } finally {
      _reading = false;
    }
  }

  void enqueue(Map<String, dynamic> value) {
    if (_closed) return;
    if (_outgoing.length + (_writing ? 1 : 0) >= limits.maxOutgoingQueue) {
      unawaited(close(3013));
      return;
    }
    final encoded = jsonEncode(value);
    if (utf8.encode(encoded).length > limits.maxBodyBytes) {
      unawaited(close(WebSocketStatus.messageTooBig));
      return;
    }
    _outgoing.add(encoded);
    if (!_writing) {
      final task = _drainOutgoing();
      _writingTask = task;
      unawaited(task);
    }
  }

  Future<void> _drainOutgoing() async {
    _writing = true;
    try {
      while (!_closed && _outgoing.isNotEmpty) {
        await socket
            .addStream(Stream<String>.value(_outgoing.removeFirst()))
            .timeout(limits.writeTimeout);
      }
    } catch (_) {
      unawaited(close(3013));
    } finally {
      _writing = false;
    }
  }

  void _done() {
    if (_closed) return;
    _closed = true;
    _statusTimer?.cancel();
    _incoming.clear();
    _outgoing.clear();
    unawaited(_eventSubscription.cancel());
    onClosed();
    if (!_finished.isCompleted) _finished.complete();
  }

  Future<void> close([int code = WebSocketStatus.normalClosure]) async {
    if (_closed) return;
    _done();
    // 先写关闭码再取消读取；在同一TCP块仍有后续帧时，先cancel可能使
    // dart:io把流取消视为协议错误，覆盖本来要发送的限流关闭码。
    try {
      // 关闭发生时可能仍有addStream占用sink。等待当前单帧释放sink，
      // 否则close会抛“stream bound”而未写关闭帧，不能以此伪成功。
      await _writingTask?.timeout(limits.writeTimeout);
      await socket.close(code).timeout(limits.writeTimeout);
    } catch (_) {
    } finally {
      await _inputSubscription.cancel();
    }
  }
}
