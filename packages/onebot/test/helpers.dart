import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';
import 'package:zaizuo_onebot/zaizuo_onebot.dart';

const token = 'local-test-token-do-not-use-in-production-123';
const secondToken = 'second-local-test-token-only-456789012345';
const fixedTime = 1700000000123;

class Fixture {
  Fixture({int eventBufferSize = 256}) {
    service = ChatService(ChatState(),
        now: () => DateTime.fromMillisecondsSinceEpoch(fixedTime, isUtc: true));
    service.registerAccount(id: 'alice', name: 'alice', displayName: 'Alice');
    service.registerAccount(id: 'bob', name: 'bob', displayName: 'Bob');
    alice = service.actor('alice');
    bob = service.actor('bob');
    service.registerBot(actor: alice, id: 'bot-a', displayName: 'Bot A');
    service.registerBot(actor: bob, id: 'bot-b', displayName: 'Bot B');
    service.addFriend(actor: alice, targetId: 'bob');
    final space = service.createSpace(
        actor: alice, id: 'space', title: 'Test space', publicChannel: true);
    roomId = space.defaultRoomId;
    service.joinSpace(actor: bob, spaceId: space.id);
    service.joinSpace(actor: alice, spaceId: space.id, botId: 'bot-a');
    service.joinSpace(actor: bob, spaceId: space.id, botId: 'bot-b');
    backend = DomainOneBotBackend(service, botId: 'bot-a');
    projection =
        OneBotProjection(backend: backend, eventBufferSize: eventBufferSize);
  }
  late final ChatService service;
  late final Actor alice;
  late final Actor bob;
  late final String roomId;
  late final DomainOneBotBackend backend;
  late final OneBotProjection projection;
  Future<Map<String, dynamic>> call(int version, String action,
          [Map<String, dynamic> params = const {}, Object? echo]) =>
      projection.handle(version,
          {'action': action, 'params': params, if (echo != null) 'echo': echo});
  int userId(String native) => projection.ids.encode('user', native);
  int groupId(String native) => projection.ids.encode('group', native);
  Future<void> close() async {
    await projection.close();
    await backend.close();
    await service.close();
  }
}

class HttpResult {
  HttpResult(this.status, this.body);
  final int status;
  final Object? body;
  Map<String, dynamic> get json => body as Map<String, dynamic>;
}

Future<HttpResult> httpCall(int port, String path, Object? body,
    {String? authorization = token,
    String? origin,
    String method = 'POST',
    String contentType = 'application/json'}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final request =
        await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    if (authorization != null)
      request.headers.set('Authorization', 'Bearer $authorization');
    if (origin != null) request.headers.set('Origin', origin);
    request.headers.set('Content-Type', contentType);
    if (body != null) request.write(body is String ? body : jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 3));
    final text = await utf8.decoder.bind(response).join();
    Object? parsed = text;
    try {
      parsed = jsonDecode(text);
    } catch (_) {}
    return HttpResult(response.statusCode, parsed);
  } finally {
    client.close(force: true);
  }
}

Future<WebSocket> connectWs(int port, int version, {String auth = token}) =>
    WebSocket.connect('ws://127.0.0.1:$port/onebot/v$version',
        headers: {'Authorization': 'Bearer $auth'},
        compression: CompressionOptions.compressionOff);

class WsInbox {
  WsInbox(WebSocket ws) {
    _subscription = ws.listen((frame) {
      final value = jsonDecode(frame as String) as Map<String, dynamic>;
      final waiter = _waiters.indexWhere((entry) => entry.$1(value));
      if (waiter >= 0) {
        _waiters.removeAt(waiter).$2.complete(value);
      } else {
        values.add(value);
      }
    }, onDone: () {
      if (!done.isCompleted) done.complete();
    });
  }
  late final StreamSubscription _subscription;
  final values = <Map<String, dynamic>>[];
  final _waiters = <(
    bool Function(Map<String, dynamic>),
    Completer<Map<String, dynamic>>
  )>[];
  final done = Completer<void>();
  Future<Map<String, dynamic>> next(
      bool Function(Map<String, dynamic>) predicate) {
    final index = values.indexWhere(predicate);
    if (index >= 0) return Future.value(values.removeAt(index));
    final completer = Completer<Map<String, dynamic>>();
    _waiters.add((predicate, completer));
    return completer.future.timeout(const Duration(seconds: 3));
  }

  Future<void> close() => _subscription.cancel();
}

void expectOk(Map<String, dynamic> value) {
  expect(value['status'], 'ok', reason: '$value');
  expect(value['retcode'], 0);
}
