import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:zaizuo_core/zaizuo_core.dart';

/// 不含密钥/房间名的路由标签；标签可被已知名称猜测，不隐藏元数据。
Future<String> relayTopic({
  required String communityId,
  required String conversationId,
}) =>
    objectHash({
      'domain': 'zaizuo.relay-topic.v1',
      'community': communityId,
      'conversation': conversationId,
    });

enum RelayLinkState { connecting, connected, disconnected, closed }

/// 固定错误码，不含令牌、URL、正文或底层异常文本。
///
/// 对调用方而言都需经 Git 补齐/确认。超时或断线不代表中继没有转发，不能
/// 通过自动重发假装 exactly-once；事件接收方仍按已签名事件 ID 去重。
class RelayLinkException implements Exception {
  const RelayLinkException(this.code);
  final String code;
  bool get requiresGit => true;
  @override
  String toString() => 'RelayLinkException($code; requiresGit=true)';
}

/// 仅表示中继处理了 publish，不表示收件人收到、验签、写盘或 Git 持久化。
class RelayPublishAck {
  const RelayPublishAck({required this.eventId, required this.topic});
  final String eventId;
  final String topic;
  bool get relayAccepted => true;
  bool get remoteDurable => false;
}

/// 将已有本地持久化密文信封送入哑中继，将收到的信封验签后写入本地日志。
///
/// 本轮只支持数字 loopback 的 ws，手动执行不跟随重定向的升级；不支持
/// WSS/公网，也不导入 OneBot 的私有实现。无业务解密/权限判定/日志输出。
class RelayLink {
  RelayLink._({
    required this.url,
    required String token,
    required this.store,
    required Set<String> topics,
    required this.onImported,
    required this.requestTimeout,
    required this.reconnectDelay,
    required this.maxPendingPublishes,
    required this.maxPendingImports,
    required this.autoReconnect,
  })  : _token = token,
        topics = Set.unmodifiable(topics);

  static Future<RelayLink> connect({
    Uri? url,
    required String token,
    required FileEventStore store,
    required Set<String> topics,
    FutureOr<void> Function(EncryptedEvent event)? onImported,
    Duration requestTimeout = const Duration(seconds: 5),
    Duration reconnectDelay = const Duration(seconds: 1),
    int maxPendingPublishes = 32,
    int maxPendingImports = 32,
    bool autoReconnect = true,
  }) async {
    final endpoint = url ?? Uri.parse('ws://127.0.0.1:8787/v1/ws');
    final address = InternetAddress.tryParse(endpoint.host);
    if (endpoint.scheme != 'ws' ||
        address == null ||
        !address.isLoopback ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        endpoint.path != '/v1/ws' ||
        endpoint.port < 1 ||
        endpoint.port > 65535) {
      throw const RelayLinkException('unsupported_endpoint');
    }
    if (token.length < 32 ||
        token.length > 256 ||
        token.codeUnits.any((byte) => byte < 0x21 || byte > 0x7e)) {
      throw const RelayLinkException('invalid_token');
    }
    if (topics.isEmpty ||
        topics.length > 64 ||
        topics.any((topic) => !_isTopic(topic)) ||
        requestTimeout <= Duration.zero ||
        reconnectDelay <= Duration.zero ||
        maxPendingPublishes < 1 ||
        maxPendingImports < 1) {
      throw const RelayLinkException('invalid_config');
    }
    final link = RelayLink._(
      url: endpoint,
      token: token,
      store: store,
      topics: topics,
      onImported: onImported,
      requestTimeout: requestTimeout,
      reconnectDelay: reconnectDelay,
      maxPendingPublishes: maxPendingPublishes,
      maxPendingImports: maxPendingImports,
      autoReconnect: autoReconnect,
    );
    try {
      await link._open();
      return link;
    } catch (_) {
      await link.close();
      throw const RelayLinkException('connect_failed');
    }
  }

  final Uri url;
  final String _token;
  final FileEventStore store;
  final Set<String> topics;
  final FutureOr<void> Function(EncryptedEvent event)? onImported;
  final Duration requestTimeout;
  final Duration reconnectDelay;
  final int maxPendingPublishes;
  final int maxPendingImports;
  final bool autoReconnect;
  final _states = StreamController<RelayLinkState>.broadcast();
  final _errors = StreamController<RelayLinkException>.broadcast();
  final Queue<_Publication> _outgoing = Queue();
  final Queue<Map<String, dynamic>> _incoming = Queue();
  RelayLinkState _state = RelayLinkState.connecting;
  _Session? _session;
  Timer? _reconnectTimer;
  HttpClient? _dialClient;
  bool _closed = false;
  bool _publishing = false;
  Future<void>? _importTask;
  Future<void>? _closing;
  int _nextRequest = 0;

  RelayLinkState get state => _state;
  bool get isConnected => !_closed && _state == RelayLinkState.connected;
  Stream<RelayLinkState> get states => _states.stream;
  Stream<RelayLinkException> get errors => _errors.stream;

  void _setState(RelayLinkState value) {
    _state = value;
    if (!_states.isClosed) _states.add(value);
  }

  void _report(String code) {
    if (!_errors.isClosed) _errors.add(RelayLinkException(code));
  }

  /// 只允许本 store 已落盘且同 ID/完整信封内容一致的事件；不重新加密。
  /// 队列满、离线、超限或 ack 不确定均明确抛错，调用方继续以 Git 为准。
  Future<RelayPublishAck> publish(EncryptedEvent event) {
    if (_closed) return Future.error(const RelayLinkException('closed'));
    if (!isConnected)
      return Future.error(const RelayLinkException('disconnected'));
    if (_outgoing.length >= maxPendingPublishes) {
      return Future.error(const RelayLinkException('queue_full'));
    }
    final serialized = canonicalJson(event.toJson());
    final persisted = store.allEnvelopes.any((existing) =>
        existing.id == event.id &&
        canonicalJson(existing.toJson()) == serialized);
    if (!persisted || event.header['community'] != store.trust.communityId) {
      return Future.error(const RelayLinkException('not_persisted'));
    }
    final bytes = utf8.encode(serialized);
    if (bytes.length > 32768) {
      return Future.error(const RelayLinkException('envelope_too_large'));
    }
    final publication = _Publication(event, base64Encode(bytes));
    _outgoing.add(publication);
    if (!_publishing) {
      _publishing = true;
      unawaited(_sendLoop());
    }
    return publication.result.future;
  }

  Future<void> _sendLoop() async {
    try {
      while (!_closed && isConnected && _outgoing.isNotEmpty) {
        final item = _outgoing.first;
        try {
          final topic = await relayTopic(
              communityId: store.trust.communityId,
              conversationId: item.event.conversation);
          // A disconnect can settle/clear the queue while hashing. Never send
          // that old publication on a newly connected replacement session.
          if (item.result.isCompleted) continue;
          if (!topics.contains(topic))
            throw const RelayLinkException('not_subscribed');
          final session = _session;
          if (session == null || !isConnected)
            throw const RelayLinkException('disconnected');
          await _request(session, 'publish', topic, payload: item.payload);
          if (!item.result.isCompleted) {
            item.result.complete(
                RelayPublishAck(eventId: item.event.id, topic: topic));
          }
        } on RelayLinkException catch (error) {
          if (!item.result.isCompleted) item.result.completeError(error);
        } catch (_) {
          if (!item.result.isCompleted) {
            item.result
                .completeError(const RelayLinkException('publish_failed'));
          }
        }
        if (_outgoing.isNotEmpty && identical(_outgoing.first, item))
          _outgoing.removeFirst();
      }
    } finally {
      _publishing = false;
    }
  }

  Future<void> _open() async {
    if (_closed) return;
    _setState(RelayLinkState.connecting);
    final transport = await _dial();
    if (_closed) {
      transport.$2.destroy();
      return;
    }
    final session = _Session(transport.$1, transport.$2);
    _session = session;
    session.socket.pingInterval = const Duration(seconds: 30);
    session.socket.done
        .then<void>((_) {}, onError: (Object _, StackTrace __) {});
    session.subscription = session.socket.listen(
      (message) => _receive(session, message),
      onError: (Object _, StackTrace __) => _lost(session, 'disconnected'),
      onDone: () => _lost(session, 'disconnected'),
      cancelOnError: true,
    );
    try {
      await session.ready.future.timeout(requestTimeout);
      for (final topic in topics) {
        await _request(session, 'subscribe', topic);
      }
      if (_closed || !identical(session, _session))
        throw const RelayLinkException('disconnected');
      _setState(RelayLinkState.connected);
    } catch (_) {
      _lost(session, 'handshake_failed');
      rethrow;
    }
  }

  Future<void> _request(_Session session, String op, String topic,
      {String? payload}) {
    if (_closed || !identical(_session, session) || session.ended) {
      return Future.error(const RelayLinkException('disconnected'));
    }
    if (session.pending != null)
      return Future.error(const RelayLinkException('request_busy'));
    final pending = _Request('r${++_nextRequest}', op, topic);
    session.pending = pending;
    pending.timer = Timer(requestTimeout, () {
      if (identical(session.pending, pending)) {
        _lost(session, 'ack_timeout');
      }
    });
    try {
      session.socket.add(jsonEncode({
        'op': op,
        'request_id': pending.id,
        'topic': topic,
        if (payload != null) 'payload': payload,
      }));
    } catch (_) {
      _lost(session, 'write_failed');
    }
    return pending.result.future;
  }

  void _receive(_Session session, dynamic message) {
    if (_closed || session.ended || !identical(_session, session)) return;
    try {
      if (message is! String ||
          message.length > 65536 ||
          utf8.encode(message).length > 65536) {
        throw const FormatException('invalid frame');
      }
      final frame = jsonObject(message);
      switch (frame['op']) {
        case 'ready':
          if (!_fields(frame, const {'op', 'version'}) ||
              frame['version'] != 1 ||
              session.ready.isCompleted) {
            throw const FormatException('invalid ready');
          }
          session.ready.complete();
        case 'ok':
          final pending = session.pending;
          if (pending == null ||
              !_fields(frame, const {'op', 'request_id', 'for', 'topic'}) ||
              frame['request_id'] != pending.id ||
              frame['for'] != pending.op ||
              frame['topic'] != pending.topic) {
            throw const FormatException('unexpected ack');
          }
          pending.timer?.cancel();
          session.pending = null;
          pending.result.complete();
        case 'error':
          final pending = session.pending;
          if (pending == null ||
              !_fields(frame, const {'op', 'request_id', 'code'}) ||
              frame['request_id'] != pending.id ||
              !const {
                'bad_request',
                'unsupported_op',
                'not_subscribed',
                'too_many_topics'
              }.contains(frame['code']))
            throw const FormatException('unexpected error');
          pending.timer?.cancel();
          session.pending = null;
          pending.result
              .completeError(const RelayLinkException('relay_rejected'));
        case 'event':
          if (!session.ready.isCompleted ||
              !_fields(frame, const {'op', 'topic', 'payload'}) ||
              frame['topic'] is! String ||
              !topics.contains(frame['topic']) ||
              frame['payload'] is! String) {
            throw const FormatException('invalid event');
          }
          if (_incoming.length + (_importTask == null ? 0 : 1) >=
              maxPendingImports) {
            _lost(session, 'import_queue_full');
            return;
          }
          _incoming.add(frame);
          _importTask ??= _importLoop().whenComplete(() => _importTask = null);
        default:
          throw const FormatException('unexpected relay operation');
      }
    } catch (_) {
      _lost(session, 'protocol_error');
    }
  }

  Future<void> _importLoop() async {
    while (!_closed && _incoming.isNotEmpty) {
      final frame = _incoming.removeFirst();
      try {
        final payload = frame['payload'] as String;
        if (payload.isEmpty ||
            payload.length > 43692 ||
            payload.length % 4 != 0) {
          throw const FormatException('invalid payload');
        }
        final bytes = base64Decode(payload);
        if (bytes.isEmpty ||
            bytes.length > 32768 ||
            base64Encode(bytes) != payload) {
          throw const FormatException('invalid payload');
        }
        final event = EncryptedEvent.fromJson(jsonObject(utf8.decode(bytes)));
        if (event.header['community'] != store.trust.communityId ||
            await relayTopic(
                    communityId: store.trust.communityId,
                    conversationId: event.conversation) !=
                frame['topic']) {
          throw const FormatException('wrong route');
        }
        await store.trust.verifyEvent(event);
        if (_closed) break;
        final bool imported;
        try {
          imported = await store.import(event); // returns only after flush
        } catch (_) {
          _report('import_failed');
          continue;
        }
        if (imported && !_closed && onImported != null) {
          try {
            await Future<void>.sync(() => onImported!(event))
                .timeout(requestTimeout);
          } catch (_) {
            _report('callback_failed'); // event remains durably stored
          }
        }
      } catch (_) {
        _report('invalid_event');
      }
    }
  }

  void _lost(_Session session, String code) {
    if (session.ended) return;
    session.ended = true;
    if (identical(_session, session)) _session = null;
    session.pending?.timer?.cancel();
    final pending = session.pending;
    session.pending = null;
    if (pending != null && !pending.result.isCompleted) {
      pending.result.completeError(RelayLinkException(code));
    }
    if (!session.ready.isCompleted)
      session.ready.completeError(RelayLinkException(code));
    session.socket.pingInterval = null;
    session.raw.destroy();
    final subscription = session.subscription;
    if (subscription != null) unawaited(subscription.cancel());
    for (final item in _outgoing) {
      if (!item.result.isCompleted)
        item.result.completeError(RelayLinkException(code));
    }
    _outgoing.clear();
    if (!_closed) {
      _setState(RelayLinkState.disconnected);
      _report(code);
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_closed || !autoReconnect || _reconnectTimer != null) return;
    _reconnectTimer = Timer(reconnectDelay, () {
      _reconnectTimer = null;
      unawaited(_retry());
    });
  }

  Future<void> _retry() async {
    if (_closed || _session != null) return;
    try {
      await _open();
    } catch (_) {
      if (!_closed) {
        _setState(RelayLinkState.disconnected);
        _report('reconnect_failed');
        _scheduleReconnect();
      }
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _dialClient?.close(force: true);
    _dialClient = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final session = _session;
    if (session != null) _lost(session, 'closed');
    _incoming.clear();
    final imports = _importTask;
    if (imports != null) {
      await imports; // close does not return while a started store.import writes
    }
    _setState(RelayLinkState.closed);
    await _states.close();
    await _errors.close();
  }

  /// HttpClient redirects are explicitly disabled; no proxy or hostname/DNS
  /// fallback can move this Bearer credential to an unrelated destination.
  Future<(WebSocket, Socket)> _dial() async {
    final client = HttpClient()..connectionTimeout = requestTimeout;
    client.findProxy = (_) => 'DIRECT';
    _dialClient = client;
    var expired = false;
    Socket? raw;
    Future<(WebSocket, Socket)> upgrade() async {
      final nonce = base64Encode(secureBytes(16));
      final request = await client.getUrl(url.replace(scheme: 'http'));
      request.followRedirects = false;
      request.headers
        ..set('Authorization', 'Bearer $_token')
        ..set('Connection', 'Upgrade')
        ..set('Upgrade', 'websocket')
        ..set('Sec-WebSocket-Version', '13')
        ..set('Sec-WebSocket-Key', nonce);
      final response = await request.close();
      if (response.statusCode != HttpStatus.switchingProtocols ||
          response.headers.value('upgrade')?.toLowerCase() != 'websocket' ||
          !(response.headers['connection'] ?? [])
              .any((value) => value.toLowerCase() == 'upgrade') ||
          response.headers['sec-websocket-extensions'] != null ||
          response.headers['sec-websocket-protocol'] != null) {
        throw const RelayLinkException('upgrade_rejected');
      }
      final accept = base64Encode((await Sha1().hash(
              ascii.encode('$nonce' '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')))
          .bytes);
      if (response.headers.value('sec-websocket-accept') != accept) {
        throw const RelayLinkException('upgrade_rejected');
      }
      final socket = raw = await response.detachSocket();
      if (expired || _closed) {
        socket.destroy();
        throw const RelayLinkException('closed');
      }
      final ws = WebSocket.fromUpgradedSocket(socket,
          serverSide: false, compression: CompressionOptions.compressionOff);
      return (ws, socket);
    }

    try {
      return await upgrade().timeout(requestTimeout);
    } catch (_) {
      expired = true;
      raw?.destroy();
      throw const RelayLinkException('connect_failed');
    } finally {
      client.close(force: true);
      if (identical(_dialClient, client)) _dialClient = null;
    }
  }
}

bool _isTopic(String value) =>
    value.length == 64 && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
bool _fields(Map<String, dynamic> value, Set<String> fields) =>
    value.length == fields.length && value.keys.every(fields.contains);

class _Session {
  _Session(this.socket, this.raw);
  final WebSocket socket;
  final Socket raw;
  final ready = Completer<void>();
  StreamSubscription<dynamic>? subscription;
  _Request? pending;
  bool ended = false;
}

class _Request {
  _Request(this.id, this.op, this.topic);
  final String id;
  final String op;
  final String topic;
  final result = Completer<void>();
  Timer? timer;
}

class _Publication {
  _Publication(this.event, this.payload);
  final EncryptedEvent event;
  final String payload;
  final result = Completer<RelayPublishAck>();
}
