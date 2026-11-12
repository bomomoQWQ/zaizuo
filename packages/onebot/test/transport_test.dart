import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zaizuo_onebot/zaizuo_onebot.dart';

import 'helpers.dart';

void main() {
  group('loopback HTTP/forward WS integration', () {
    late Fixture f;
    late OneBotServer server;
    setUp(() async {
      f = Fixture();
      server = OneBotServer(
          bindings: [OneBotBinding(token: token, projection: f.projection)]);
      await server.start();
    });
    tearDown(() async {
      await server.close();
      await f.close();
    });

    test(
        'HTTP auth, Origin, URL token, method, content-type and routes are rejected',
        () async {
      final body = {'action': 'get_status', 'params': {}};
      expect(
          (await httpCall(server.port, '/onebot/v12', body,
                  authorization: null))
              .status,
          401);
      expect(
          (await httpCall(server.port, '/onebot/v11', body,
                  authorization: 'wrong'))
              .status,
          401);
      expect(
          (await httpCall(server.port, '/onebot/v12', body,
                  origin: 'https://evil.invalid'))
              .status,
          403);
      expect(
          (await httpCall(server.port, '/onebot/v12?access_token=$token', body))
              .status,
          400);
      expect(
          (await httpCall(server.port, '/onebot/v12', null, method: 'GET'))
              .status,
          405);
      expect((await httpCall(server.port, '/onebot/v13', body)).status, 404);
      expect(
          (await httpCall(server.port, '/onebot/v12', body,
                  contentType: 'application/msgpack'))
              .status,
          415);
      expect(
          (await httpCall(server.port, '/onebot/v11', body,
                  contentType: 'text/plain'))
              .status,
          406);
      final bad = await httpCall(server.port, '/onebot/v12', '{bad');
      expect(bad.status, 200);
      expect(bad.json['retcode'], 10001);
      expect((await httpCall(server.port, '/onebot/v11', '{bad')).status, 400);
    });

    test(
        'HTTP v11 path actions and dual endpoint envelopes preserve echo and binding',
        () async {
      final login = await httpCall(server.port, '/onebot/v11/get_login_info', {
        'echo': {
          'a': [1, true]
        }
      });
      expect(login.status, 200);
      expectOk(login.json);
      expect(login.json['echo'], {
        'a': [1, true]
      });
      expect(login.json['data']['user_id'], f.userId('bot-a'));
      final sent11 = await httpCall(server.port, '/onebot/v11/send_group_msg',
          {'group_id': f.groupId(f.roomId), 'message': 'from 11', 'echo': 7});
      expectOk(sent11.json);
      expect(sent11.json['echo'], 7);
      final sent12 = await httpCall(server.port, '/onebot/v12', {
        'action': 'send_message',
        'params': {
          'detail_type': 'group',
          'group_id': f.roomId,
          'message': 'from 12'
        },
        'echo': 'e12'
      });
      expectOk(sent12.json);
      expect(sent12.json['echo'], 'e12');
      expect(f.service.state.messages.values.map((value) => value.senderId),
          everyElement('bot-a'));
      final denied = await httpCall(server.port, '/onebot/v12', {
        'action': 'get_status',
        'params': {},
        'self': {'platform': 'zaizuo', 'user_id': 'bot-b'}
      });
      expect(denied.status, 200);
      expect(denied.json['retcode'], 10102);
    });

    test(
        'forward WS 11/12 same incoming domain event; HTTP polling independent; shutdown closes both',
        () async {
      final ws11 = await connectWs(server.port, 11);
      final ws12 = await connectWs(server.port, 12);
      final inbox11 = WsInbox(ws11);
      final inbox12 = WsInbox(ws12);
      expect(
          (await inbox11.next(
              (value) => value['meta_event_type'] == 'lifecycle'))['sub_type'],
          'connect');
      final connect =
          await inbox12.next((value) => value['detail_type'] == 'connect');
      expect(connect['version']['onebot_version'], '12');
      expect(
          (await inbox12.next(
                  (value) => value['detail_type'] == 'status_update'))['status']
              ['bots'],
          hasLength(1));
      addTearDown(inbox11.close);
      addTearDown(inbox12.close);
      ws11.add(jsonEncode({
        'action': 'get_login_info',
        'echo': ['any', 9]
      }));
      ws12.add(jsonEncode(
          {'action': 'get_self_info', 'params': {}, 'echo': 'self12'}));
      expect(
          (await inbox11.next((value) => value.containsKey('retcode')))['echo'],
          ['any', 9]);
      expect(
          (await inbox12.next((value) => value.containsKey('retcode')))['echo'],
          'self12');
      final incoming =
          f.service.sendMessage(actor: f.bob, conversationId: f.roomId, parts: [
        {
          'type': 'text',
          'data': {'text': 'incoming'}
        }
      ]);
      final e11 =
          await inbox11.next((value) => value['post_type'] == 'message');
      final e12 = await inbox12.next((value) => value['type'] == 'message');
      expect(
          f.projection.ids.decode('message', e11['message_id']), incoming.id);
      expect(e12['message_id'], incoming.id);
      expect(e12['time'], fixedTime / 1000);
      final polled = await httpCall(server.port, '/onebot/v12',
          {'action': 'get_latest_events', 'params': {}});
      expect((polled.json['data'] as List).single['id'], e12['id']);
      final done11 = inbox11.done.future;
      final done12 = inbox12.done.future;
      await server.close();
      await Future.wait([done11, done12]).timeout(const Duration(seconds: 3));
    });

    test('WS unauthorized rejected before upgrade and wrong self cannot send',
        () async {
      await expectLater(connectWs(server.port, 12, auth: 'wrong'),
          throwsA(isA<WebSocketException>()));
      final ws = await connectWs(server.port, 12);
      final inbox = WsInbox(ws);
      addTearDown(inbox.close);
      addTearDown(ws.close);
      ws.add(jsonEncode({
        'action': 'send_message',
        'params': {
          'detail_type': 'group',
          'group_id': f.roomId,
          'message': 'must not send'
        },
        'self': {'platform': 'zaizuo', 'user_id': 'bot-b'},
        'echo': 'badself'
      }));
      final response = await inbox.next((value) => value['echo'] == 'badself');
      expect(response['retcode'], 10102);
      expect(f.service.state.messages, isEmpty);
    });
  });

  test('fixed token binding isolates two bot connections', () async {
    final f = Fixture();
    final b = DomainOneBotBackend(f.service, botId: 'bot-b');
    final p = OneBotProjection(backend: b);
    final server = OneBotServer(bindings: [
      OneBotBinding(token: token, projection: f.projection),
      OneBotBinding(token: secondToken, projection: p)
    ]);
    await server.start();
    addTearDown(() async {
      await server.close();
      await p.close();
      await b.close();
      await f.close();
    });
    final selfB = await httpCall(
        server.port, '/onebot/v12', {'action': 'get_self_info', 'params': {}},
        authorization: secondToken);
    expect(selfB.json['data']['user_id'], 'bot-b');
    final forbidden = await httpCall(
        server.port,
        '/onebot/v12',
        {
          'action': 'get_self_info',
          'params': {},
          'self': {'platform': 'zaizuo', 'user_id': 'bot-a'}
        },
        authorization: secondToken);
    expect(forbidden.json['retcode'], 10102);
  });

  test(
      'WS incoming queue and declared huge frame lengths are bounded before JSON allocation',
      () async {
    final f = Fixture();
    final server = OneBotServer(
        bindings: [OneBotBinding(token: token, projection: f.projection)],
        limits: const OneBotLimits(maxIncomingQueue: 2, maxBodyBytes: 1024));
    await server.start();
    addTearDown(() async {
      await server.close();
      await f.close();
    });
    final ws = await connectWs(server.port, 12);
    final inbox = WsInbox(ws);
    addTearDown(inbox.close);
    ws.add(jsonEncode({
      'action': 'get_latest_events',
      'params': {'timeout': 10}
    }));
    for (var i = 0; i < 4; i++) {
      ws.add(jsonEncode({'action': 'get_status', 'params': {}, 'echo': '$i'}));
    }
    await inbox.done.future.timeout(const Duration(seconds: 3));
    expect(ws.closeCode, 3013); // dart:io保留1013，明确使用在座应用关闭码。
    await f.projection.close();

    // 只发送声明为巨大帧的header，不发送巨大payload；服务应立即终止。
    final raw = await Socket.connect('127.0.0.1', server.port);
    final upgraded = Completer<void>();
    final finished = Completer<void>();
    raw.listen((chunk) {
      if (!upgraded.isCompleted && latin1.decode(chunk).contains('101'))
        upgraded.complete();
    }, onDone: () {
      if (!finished.isCompleted) finished.complete();
    });
    raw.write(
        'GET /onebot/v12 HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer $token\r\n'
        'Connection: Upgrade\r\nUpgrade:\tWebSocket\r\nSec-WebSocket-Version: 13\r\n'
        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n');
    await raw.flush();
    await upgraded.future.timeout(const Duration(seconds: 3));
    raw.add([0x81, 0xff, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00]);
    await raw.flush();
    await finished.future.timeout(const Duration(seconds: 3));
    raw.destroy();
  });

  test(
      'header deadline and header/body byte caps terminate bounded local requests',
      () async {
    final f = Fixture();
    final server = OneBotServer(
        bindings: [OneBotBinding(token: token, projection: f.projection)],
        limits: const OneBotLimits(
            maxHeaderBytes: 1024,
            maxBodyBytes: 256,
            headerTimeout: Duration(milliseconds: 100),
            bodyTimeout: Duration(milliseconds: 100)));
    await server.start();
    addTearDown(() async {
      await server.close();
      await f.close();
    });
    final slow = await Socket.connect('127.0.0.1', server.port);
    final slowDone = slow.drain<void>();
    slow.write('POST /onebot/v12 HTTP/1.1\r\nHost: localhost\r\n');
    await slow.flush();
    await slowDone.timeout(const Duration(seconds: 2));
    slow.destroy();
    final huge = await Socket.connect('127.0.0.1', server.port);
    final hugeDone = huge.drain<void>();
    huge.write('POST /onebot/v12 HTTP/1.1\r\nX-Padding: ${'a' * 1200}\r\n\r\n');
    await huge.flush();
    await hugeDone.timeout(const Duration(seconds: 2));
    huge.destroy();
    // 超额chunked正文可能写出10001，也可能由dart:io直接终止；两者都不能成功。
    try {
      final rejected = await httpCall(server.port, '/onebot/v12', {
        'action': 'get_status',
        'params': {'oversized': 'a' * 512}
      });
      expect(rejected.json['status'], 'failed');
      expect(rejected.json['retcode'], 10001);
    } on HttpException {
      // 资源拒绝后的连接终止是明确允许的边界。
    }
    expect(f.service.state.messages, isEmpty);
  });
}
