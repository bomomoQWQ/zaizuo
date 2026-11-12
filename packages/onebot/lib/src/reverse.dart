import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'guarded_socket.dart';
import 'projection.dart';
import 'transport.dart';

/// 凭据只会发给本地配置精确允许的端点；请求/事件参数不能更改此配置。
class ReverseWebSocketConfig {
  ReverseWebSocketConfig(
      {required this.url,
      required this.version,
      required this.token,
      required Set<Uri> trustedUrls,
      this.enabled = false,
      this.reconnectInterval = const Duration(seconds: 3),
      this.connectTimeout = const Duration(seconds: 5)})
      : trustedUrls = Set.unmodifiable(trustedUrls) {
    validateLocalToken(token);
    if (version != 11 && version != 12)
      throw ArgumentError('Invalid OneBot version');
    if (reconnectInterval <= Duration.zero || connectTimeout <= Duration.zero) {
      throw ArgumentError('Reverse WS timeouts must be positive');
    }
    if (!this.trustedUrls.contains(url) ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        (url.scheme != 'ws' && url.scheme != 'wss')) {
      throw ArgumentError('Reverse URL is not an explicitly trusted endpoint');
    }
    if (url.scheme == 'ws') {
      final address = InternetAddress.tryParse(url.host);
      if (address == null || !address.isLoopback) {
        throw ArgumentError('Plain WS must use a numeric loopback address');
      }
    }
  }
  final Uri url;
  final int version;
  final String token;
  final Set<Uri> trustedUrls;
  final bool enabled;
  final Duration reconnectInterval;
  final Duration connectTimeout;
}

/// 反向 WS universal 客户端，带可取消重连；不跟随重定向、不使用代理。
class OneBotReverseClient {
  OneBotReverseClient(
      {required this.projection,
      required this.config,
      this.limits = const OneBotLimits()}) {
    limits.validate();
  }
  final OneBotProjection projection;
  final ReverseWebSocketConfig config;
  final OneBotLimits limits;
  OneBotWsPeer? _peer;
  Socket? _connecting;
  Timer? _retryTimer;
  Completer<void>? _retry;
  Future<void>? _run;
  bool _closed = false;
  bool get connected => _peer != null;
  int connectionAttempts = 0;
  int successfulConnections = 0;
  final _connections = StreamController<void>.broadcast();
  Stream<void> get connections => _connections.stream;

  void start() {
    if (!config.enabled)
      throw StateError('Reverse WS is disabled; enable explicitly');
    if (_closed || _run != null)
      throw StateError('Reverse WS already started/closed');
    _run = _loop();
  }

  Future<void> _loop() async {
    while (!_closed) {
      connectionAttempts++;
      try {
        // 各网络阶段自身有超时；不能用不能取消底层工作的 Future.timeout
        // 包住整次尝试，否则旧TCP连接迟到会与新尝试重叠。
        final ws = await _connect();
        if (_closed) {
          await ws.close(WebSocketStatus.goingAway);
          break;
        }
        late final OneBotWsPeer peer;
        peer =
            OneBotWsPeer(ws, projection, config.version, limits, onClosed: () {
          if (identical(_peer, peer)) _peer = null;
        });
        _peer = peer;
        successfulConnections++;
        _connections.add(null);
        await peer.done;
      } catch (_) {
        // 不记录异常或 URL：系统异常可能包含带身份信息的目标。
      } finally {
        _connecting?.destroy();
        _connecting = null;
      }
      if (_closed) break;
      final retry = Completer<void>();
      _retry = retry;
      _retryTimer = Timer(config.reconnectInterval, retry.complete);
      await retry.future;
      _retryTimer = null;
      if (identical(_retry, retry)) _retry = null;
    }
  }

  Future<WebSocket> _connect() async {
    final uri = config.url;
    final raw = uri.scheme == 'wss'
        ? await SecureSocket.connect(uri.host, uri.hasPort ? uri.port : 443,
            timeout: config.connectTimeout)
        : await Socket.connect(uri.host, uri.hasPort ? uri.port : 80,
            timeout: config.connectTimeout);
    if (_closed) {
      raw.destroy();
      throw StateError('Closed');
    }
    _connecting = raw;
    // 自己读取一次 HTTP upgrade，绝不使用会默认重定向的 HTTP 客户端。
    final socket = raw;
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final key = base64Encode(bytes);
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    final hostHeader = uri.hasPort ? '$host:${uri.port}' : host;
    final path = uri.path.isEmpty ? '/' : uri.path;
    final request = StringBuffer()
      ..write('GET $path HTTP/1.1\r\nHost: $hostHeader\r\n')
      ..write('Upgrade: websocket\r\nConnection: Upgrade\r\n')
      ..write('Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: $key\r\n')
      ..write('Authorization: Bearer ${config.token}\r\n')
      ..write(
          'User-Agent: OneBot/${config.version} (zaizuo) zaizuo/$oneBotImplementationVersion\r\n');
    if (config.version == 12) {
      request.write('Sec-WebSocket-Protocol: 12.zaizuo\r\n');
    } else {
      request.write(
          'X-Self-ID: ${projection.ids.encode('user', projection.backend.botId)}\r\n'
          'X-Client-Role: Universal\r\n');
    }
    request.write('\r\n');
    socket.add(ascii.encode(request.toString()));
    await socket.flush().timeout(limits.writeTimeout);

    final header = <int>[];
    final ready = Completer<String>();
    var upgraded = false;
    var tail = 0;
    late final StreamSubscription<Uint8List> subscription;
    late final StreamController<Uint8List> frames;
    frames = StreamController<Uint8List>(
        sync: true,
        onListen: () => subscription.resume(),
        onPause: () => subscription.pause(),
        onResume: () => subscription.resume(),
        onCancel: () => subscription.cancel());
    subscription = socket.listen((chunk) {
      if (upgraded) {
        frames.add(chunk);
        return;
      }
      for (var i = 0; i < chunk.length; i++) {
        final byte = chunk[i];
        header.add(byte);
        tail = ((tail << 8) | byte) & 0xffffffff;
        if (header.length > limits.maxHeaderBytes) {
          if (!ready.isCompleted)
            ready.completeError(const FormatException('Header too large'));
          socket.destroy();
          return;
        }
        if (tail == 0x0d0a0d0a) {
          upgraded = true;
          subscription.pause();
          if (i + 1 < chunk.length)
            frames.add(Uint8List.sublistView(chunk, i + 1));
          ready.complete(latin1.decode(header));
          return;
        }
      }
    }, onDone: () {
      if (!ready.isCompleted)
        ready.completeError(const FormatException('Incomplete header'));
      unawaited(frames.close());
    }, onError: (Object error) {
      if (!ready.isCompleted) {
        ready.completeError(const FormatException('Handshake failed'));
      } else {
        frames.addError(error);
      }
    });
    try {
      final text = await ready.future.timeout(config.connectTimeout);
      final lines = text.split('\r\n');
      if (!RegExp(r'^HTTP/1\.[01] 101(?: |$)').hasMatch(lines.first)) {
        throw const FormatException('Upgrade required; redirects refused');
      }
      final headers = <String, String>{};
      for (final line in lines.skip(1).where((value) => value.isNotEmpty)) {
        final colon = line.indexOf(':');
        if (colon < 1) throw const FormatException('Malformed response header');
        final name = line.substring(0, colon).toLowerCase();
        if (headers.containsKey(name))
          throw const FormatException('Duplicate response header');
        headers[name] = line.substring(colon + 1).trim();
      }
      final expected = base64Encode(sha1
          .convert(ascii.encode('$key' '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))
          .bytes);
      if (headers['sec-websocket-accept'] != expected ||
          headers['upgrade']?.toLowerCase() != 'websocket' ||
          !(headers['connection']
                  ?.toLowerCase()
                  .split(',')
                  .map((value) => value.trim())
                  .contains('upgrade') ??
              false) ||
          headers.containsKey('sec-websocket-extensions') ||
          (headers.containsKey('sec-websocket-protocol') &&
              headers['sec-websocket-protocol'] !=
                  (config.version == 12 ? '12.zaizuo' : null))) {
        throw const FormatException('Invalid upgrade response');
      }
      final guarded = GuardedSocket(
          raw, limits.maxHeaderBytes, config.connectTimeout, () {},
          input: frames.stream, headersComplete: true)
        ..guardWebSocket(limits.maxBodyBytes);
      _connecting = guarded;
      return WebSocket.fromUpgradedSocket(guarded,
          serverSide: false,
          protocol:
              config.version == 12 ? headers['sec-websocket-protocol'] : null,
          compression: CompressionOptions.compressionOff);
    } catch (_) {
      socket.destroy();
      await subscription.cancel();
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _retryTimer?.cancel();
    if (_retry != null && !_retry!.isCompleted) _retry!.complete();
    _connecting?.destroy();
    await _peer?.close(WebSocketStatus.goingAway);
    await _run;
    await _connections.close();
  }
}
