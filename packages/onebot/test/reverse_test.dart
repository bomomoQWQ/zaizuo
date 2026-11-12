import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zaizuo_onebot/zaizuo_onebot.dart';

import 'helpers.dart';

void main() {
  test(
      'reverse requires explicit enable and exact trusted URL; cleartext nonloopback/URL secrets rejected',
      () async {
    final f = Fixture();
    addTearDown(f.close);
    final uri = Uri.parse('ws://127.0.0.1:12345/reverse');
    final disabled = OneBotReverseClient(
        projection: f.projection,
        config: ReverseWebSocketConfig(
            url: uri, version: 12, token: token, trustedUrls: {uri}));
    expect(disabled.start, throwsStateError);
    await disabled.close();
    expect(
        () => ReverseWebSocketConfig(
            url: uri, version: 12, token: token, trustedUrls: {}),
        throwsArgumentError);
    for (final value in [
      'ws://example.invalid/onebot',
      'ws://localhost/onebot',
      'wss://user:pass@example.invalid/onebot',
      'wss://example.invalid/onebot?access_token=secret',
      'wss://example.invalid/onebot#fragment',
      'https://example.invalid/onebot'
    ]) {
      final bad = Uri.parse(value);
      expect(
          () => ReverseWebSocketConfig(
              url: bad, version: 12, token: token, trustedUrls: {bad}),
          throwsArgumentError);
    }
  });

  for (final version in [11, 12]) {
    test(
        'reverse v$version handshake/actions/events reconnect and shutdown stop existing socket/retries',
        () async {
      final f = Fixture();
      final remote = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final requests = <HttpRequest>[];
      final arrivals = StreamController<WebSocket>.broadcast();
      remote.listen((request) async {
        requests.add(request);
        final ws = await WebSocketTransformer.upgrade(request,
            protocolSelector: version == 12
                ? (values) => values.contains('12.zaizuo') ? '12.zaizuo' : null
                : null,
            compression: CompressionOptions.compressionOff);
        sockets.add(ws);
        arrivals.add(ws);
      });
      final url = Uri.parse('ws://127.0.0.1:${remote.port}/reverse');
      final reverse = OneBotReverseClient(
          projection: f.projection,
          config: ReverseWebSocketConfig(
              url: url,
              version: version,
              token: token,
              trustedUrls: {url},
              enabled: true,
              reconnectInterval: const Duration(milliseconds: 50)));
      addTearDown(() async {
        await reverse.close();
        for (final ws in sockets) {
          await ws.close();
        }
        await arrivals.close();
        await remote.close(force: true);
        await f.close();
      });
      final first = arrivals.stream.first;
      reverse.start();
      final ws = await first.timeout(const Duration(seconds: 3));
      final inbox = WsInbox(ws);
      addTearDown(inbox.close);
      ws.add(jsonEncode({
        'action': version == 11 ? 'get_login_info' : 'get_self_info',
        'params': {},
        'echo': version == 11 ? {'reverse': true} : 'reverse'
      }));
      final response =
          await inbox.next((value) => value.containsKey('retcode'));
      expectOk(response);
      expect(requests.single.headers.value('authorization'), 'Bearer $token');
      expect(requests.single.uri.query, isEmpty);
      if (version == 11) {
        expect(
            requests.single.headers.value('x-self-id'), '${f.userId('bot-a')}');
        expect(requests.single.headers.value('x-client-role'), 'Universal');
      } else {
        expect(
            requests.single.headers.value('user-agent'), contains('OneBot/12'));
        expect(requests.single.headers.value('sec-websocket-protocol'),
            '12.zaizuo');
      }
      f.service.sendMessage(actor: f.bob, conversationId: f.roomId, parts: [
        {
          'type': 'text',
          'data': {'text': 'reverse incoming'}
        }
      ]);
      final event = await inbox.next(
          (value) => value[version == 11 ? 'post_type' : 'type'] == 'message');
      expect(event['message'].single['data']['text'], 'reverse incoming');
      final secondArrival = arrivals.stream.first;
      final secondConnected = reverse.connections.first;
      await ws.close(WebSocketStatus.goingAway);
      final second = await secondArrival.timeout(const Duration(seconds: 3));
      await secondConnected.timeout(const Duration(seconds: 3));
      final secondInbox = WsInbox(second);
      addTearDown(secondInbox.close);
      expect(reverse.successfulConnections, 2);
      await reverse.close();
      await secondInbox.done.future.timeout(const Duration(seconds: 3));
      final attempts = reverse.connectionAttempts;
      await expectLater(
          arrivals.stream.first.timeout(const Duration(milliseconds: 180)),
          throwsA(isA<TimeoutException>()));
      expect(reverse.connectionAttempts, attempts);
    });
  }

  test('reverse refuses redirect without sending credentials to target',
      () async {
    final f = Fixture();
    final redirect = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var targetHits = 0;
    target.listen((request) {
      targetHits++;
      request.response.close();
    });
    final attempted = Completer<void>();
    redirect.listen((request) async {
      request.response.statusCode = 302;
      request.response.headers
          .set('Location', 'http://127.0.0.1:${target.port}/stolen');
      await request.response.close();
      if (!attempted.isCompleted) attempted.complete();
    });
    final url = Uri.parse('ws://127.0.0.1:${redirect.port}/configured');
    final client = OneBotReverseClient(
        projection: f.projection,
        config: ReverseWebSocketConfig(
            url: url,
            version: 12,
            token: token,
            trustedUrls: {url},
            enabled: true,
            reconnectInterval: const Duration(seconds: 1)));
    addTearDown(() async {
      await client.close();
      await redirect.close(force: true);
      await target.close(force: true);
      await f.close();
    });
    client.start();
    await attempted.future.timeout(const Duration(seconds: 3));
    await client.close();
    expect(targetHits, 0);
    expect(client.successfulConnections, 0);
  });
}
