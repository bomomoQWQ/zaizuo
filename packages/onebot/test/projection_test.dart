import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';
import 'package:zaizuo_onebot/zaizuo_onebot.dart';

import 'helpers.dart';

void main() {
  test(
      'v11 stable IDs are bijective and survive export/load, invalid state rejected',
      () {
    final ids = OneBotIdMap();
    final issued = <int>{};
    for (var i = 0; i < 10000; i++) {
      expect(issued.add(ids.encode('user', 'native:$i')), isTrue);
    }
    final again = OneBotIdMap.loadState(ids.exportState());
    for (var i = 0; i < 10000; i++) {
      expect(again.encode('user', 'native:$i'), i + 1);
      expect(again.decode('user', '${i + 1}'), 'native:$i');
    }
    expect(again.encode('user', 'new'), 10001);
    final corrupt = jsonDecode(ids.exportState()) as Map<String, dynamic>;
    corrupt['spaces']['user']['entries']['collision'] = 1;
    expect(() => OneBotIdMap.fromJson(corrupt), throwsFormatException);
    expect(ids.decode('user', 1.0), isNull);
  });

  test(
      'ID synchronous persistence failure rolls back and fail-closes without reusing published IDs',
      () {
    Map<String, dynamic>? saved;
    var failing = false;
    final ids = OneBotIdMap(onChanged: (state) {
      if (failing) throw StateError('simulated disk failure');
      saved = state;
    });
    final published = ids.encode('message', 'published');
    expect(published, 1);
    expect(saved!['spaces']['message']['entries']['published'], 1);
    failing = true;
    expect(() => ids.encode('message', 'not-published'), throwsStateError);
    expect(ids.persistenceFailed, isTrue);
    expect(ids.toJson()['spaces']['message']['entries'], {'published': 1});
    expect(() => ids.encode('message', 'third'), throwsStateError);
    final restored = OneBotIdMap.fromJson(saved!, onChanged: (state) {
      saved = state;
    });
    expect(restored.encode('message', 'published'), published);
    expect(restored.encode('message', 'third'), 2);
    expect(restored.decode('message', published), 'published');
  });

  test(
      'ID asynchronous callback is explicitly rejected rather than returning unpersisted success',
      () async {
    final ids = OneBotIdMap(onChanged: (state) async {});
    expect(() => ids.encode('user', 'u'), throwsStateError);
    expect(ids.persistenceFailed, isTrue);
    await Future<void>.delayed(Duration.zero);
  });

  test(
      'CQ entity roundtrip, one-pass unescape, comma/equal parsing, v12 string stays text',
      () {
    final parts = <Map<String, dynamic>>[
      {
        'type': 'text',
        'data': {'text': '[x] & &#91;, literal'}
      },
      {
        'type': 'share',
        'data': {'title': 'a,b=c[]&', 'url': 'https://example.invalid/?x=1&y=2'}
      },
    ];
    expect(CqCodec.parse(CqCodec.format(parts)), parts);
    expect(CqCodec.parse('&amp;#91;CQ:at,qq=all&amp;#93;').single['data'],
        {'text': '&#91;CQ:at,qq=all&#93;'});
    expect(CqCodec.parse('[CQ:share,title=a=b&#44;c]').single['data'],
        {'title': 'a=b,c'});
    final codec = OneBotMessageCodec(OneBotIdMap());
    expect(codec.decode('[CQ:at,qq=all]', 12), [
      {
        'type': 'text',
        'data': {'text': '[CQ:at,qq=all]'}
      },
    ]);
    expect(codec.decode('[CQ:at,qq=all]', 11).single['type'], 'mention_all');
  });

  group('domain-backed dual projection', () {
    late Fixture f;
    setUp(() {
      f = Fixture();
    });
    tearDown(() => f.close());

    test(
        'same bot v11/v12 sends original identity, stable cross-protocol message IDs, seconds',
        () async {
      final sent11 = await f.call(11, 'send_msg', {
        'group_id': f.groupId(f.roomId),
        'message': 'hi &#91;x&#93; [CQ:at,qq=all]'
      });
      expectOk(sent11);
      final native11 =
          f.projection.ids.decode('message', sent11['data']['message_id'])!;
      final record11 = f.service
          .message(actor: f.service.actor('bot-a'), messageId: native11);
      expect(record11.senderId, 'bot-a');
      expect(record11.parts.first['data'], {'text': 'hi [x] '});
      expect(record11.parts.last['type'], 'mention_all');
      final get11 = await f
          .call(11, 'get_msg', {'message_id': sent11['data']['message_id']});
      expectOk(get11);
      expect(get11['data']['time'], fixedTime ~/ 1000);
      expect(get11['data']['real_id'], sent11['data']['message_id']);
      final sent12 = await f.call(12, 'send_message', {
        'detail_type': 'group',
        'group_id': f.roomId,
        'message': '[CQ:at,qq=all]'
      });
      expectOk(sent12);
      expect(sent12['data']['time'], fixedTime / 1000);
      final native12 = sent12['data']['message_id'] as String;
      final mapped = f.projection.ids.encode('message', native12);
      final read12in11 = await f.call(11, 'get_msg', {'message_id': mapped});
      expectOk(read12in11);
      expect(read12in11['data']['message'], [
        {
          'type': 'text',
          'data': {'text': '[CQ:at,qq=all]'}
        },
      ]);
      final private = await f.call(11, 'send_private_msg', {
        'user_id': f.userId('bob'),
        'message': 'private',
        'auto_escape': true
      });
      expectOk(private);
      final private12 = await f.call(12, 'send_message', {
        'detail_type': 'private',
        'user_id': 'bob',
        'message': [
          {
            'type': 'text',
            'data': {'text': 'again'}
          }
        ]
      });
      expectOk(private12);
      final records = f.service.state.messages.values;
      expect(records.every((record) => record.senderId == 'bot-a'), isTrue);
    });

    test(
        'echo v11 arbitrary JSON/null and v12 string/empty preserved; wrong type fails',
        () async {
      for (final echo in [
        null,
        false,
        4,
        [
          1,
          {'nested': true}
        ],
        {'key': 'value'}
      ]) {
        final response = await f.projection.handle(
            11, {'action': 'get_login_info', 'params': {}, 'echo': echo});
        expectOk(response);
        expect(response.containsKey('echo'), isTrue);
        expect(response['echo'], echo);
      }
      for (final echo in ['', 'echo-string']) {
        final response = await f.projection.handle(
            12, {'action': 'get_self_info', 'params': {}, 'echo': echo});
        expectOk(response);
        expect(response['echo'], echo);
      }
      expect(
          (await f.projection.handle(12,
              {'action': 'get_self_info', 'params': {}, 'echo': 1}))['retcode'],
          10001);
      expect(
          (await f.projection.handle(12, {'action': 'get_status'}))['retcode'],
          10001);
    });

    test('self in envelope or params never switches bot even for meta actions',
        () async {
      final wrong = {'platform': 'zaizuo', 'user_id': 'bot-b'};
      for (final version in [11, 12]) {
        final response = await f.projection.handle(version, {
          'action': 'get_status',
          'params': {},
          'self': wrong,
          'echo': 'kept'
        });
        expect(response['status'], 'failed');
        expect(response['echo'], 'kept');
        expect(response['retcode'], version == 12 ? 10102 : 1403);
        expect((await f.call(version, 'get_status', {'self': wrong}))['status'],
            'failed');
      }
      expect(
          (await f.call(
              11, 'get_status', {'self_id': f.userId('bot-b')}))['retcode'],
          1403);
      expectOk(await f.projection.handle(12, {
        'action': 'get_self_info',
        'params': {},
        'self': {'platform': 'zaizuo', 'user_id': 'bot-a'}
      }));
    });

    test('profile, lists, truthful support/version and unsupported deletion',
        () async {
      final info = await f.call(12, 'get_self_info');
      expect(info['data'], {
        'user_id': 'bot-a',
        'user_name': 'Bot A',
        'user_displayname': 'Bot A'
      });
      for (final version in [11, 12]) {
        expectOk(await f.call(version, 'get_friend_list'));
        final groups = await f.call(version, 'get_group_list');
        expectOk(groups);
        expect((groups['data'] as List).length, 2); // 主房间与独立茶会。
        expectOk(await f.call(version, 'get_group_member_list',
            {'group_id': version == 11 ? f.groupId(f.roomId) : f.roomId}));
        expect(
            (await f.call(
                version,
                version == 11 ? 'delete_msg' : 'delete_message',
                {'message_id': version == 11 ? 1 : 'x'}))['retcode'],
            version == 11 ? 1404 : 10002);
      }
      expectOk(await f.call(12, 'get_user_info', {'user_id': 'bob'}));
      expectOk(await f.call(12, 'get_group_info', {'group_id': f.roomId}));
      final supported =
          (await f.call(12, 'get_supported_actions'))['data'] as List;
      expect(supported, contains('send_message'));
      expect(supported, isNot(contains('delete_message')));
      expect((await f.call(12, 'get_version'))['data']['zaizuo.compatibility'],
          'subset');
      expect((await f.call(11, 'get_version_info'))['data']['protocol_version'],
          'v11');
    });

    test(
        'domain permissions errors mapped, no sender spoof or hidden history leak',
        () async {
      final message = f.service
          .sendMessage(actor: f.alice, conversationId: f.roomId, parts: [
        {
          'type': 'text',
          'data': {'text': 'existing'}
        }
      ]);
      f.service.mute(actor: f.alice, spaceId: 'space', principalId: 'bot-a');
      final one = await f.call(11, 'send_group_msg',
          {'group_id': f.groupId(f.roomId), 'message': 'blocked'});
      final two = await f.call(12, 'send_message',
          {'detail_type': 'group', 'group_id': f.roomId, 'message': 'blocked'});
      expect(one['retcode'], 1403);
      expect(two['retcode'], 35001);
      f.service.setBotCaps(
          actor: f.alice, botId: 'bot-a', caps: {BotCapability.sendMessage});
      final read = await f.call(11, 'get_msg',
          {'message_id': f.projection.ids.encode('message', message.id)});
      expect(read['retcode'], 1403);
      final events = await f.call(12, 'get_latest_events');
      expect(events['data'], isEmpty);
    });

    test(
        'domain channels map guild+conversation, not ambiguous default room alias',
        () async {
      expect((await f.call(12, 'get_guild_list'))['data'], [
        {'guild_id': 'space', 'guild_name': 'Test space'}
      ]);
      final channels = (await f
          .call(12, 'get_channel_list', {'guild_id': 'space'}))['data'] as List;
      expect(channels.map((value) => value['channel_id']), contains(f.roomId));
      expectOk(await f.call(12, 'get_channel_info',
          {'guild_id': 'space', 'channel_id': f.roomId}));
      final sent = await f.call(12, 'send_message', {
        'detail_type': 'channel',
        'guild_id': 'space',
        'channel_id': f.roomId,
        'message': 'channel'
      });
      expectOk(sent);
      expect(
          (await f.call(12, 'send_message', {
            'detail_type': 'channel',
            'guild_id': 'wrong',
            'channel_id': f.roomId,
            'message': 'channel'
          }))['status'],
          'failed');
      expect(f.service.state.messages.values.single.conversationId, f.roomId);
    });

    test(
        'get_latest_events independently buffers, consumes oldest, long-polls, bounded',
        () async {
      final events = <OneBotEvent>[];
      final sub = f.projection.events.listen(events.add);
      final pending =
          f.call(12, 'get_latest_events', {'timeout': 1, 'limit': 1});
      final message =
          f.service.sendMessage(actor: f.bob, conversationId: f.roomId, parts: [
        {
          'type': 'text',
          'data': {'text': 'incoming'}
        }
      ]);
      final polled = await pending;
      expectOk(polled);
      expect(polled['data'].single['message_id'], message.id);
      expect(polled['data'].single['time'], fixedTime / 1000);
      expect(polled['data'].single['detail_type'], 'channel');
      expect(events.single.v11['message_type'], 'group');
      expect(events.single.v12['self'],
          {'platform': 'zaizuo', 'user_id': 'bot-a'});
      expect((await f.call(12, 'get_latest_events'))['data'], isEmpty);
      await sub.cancel();
    });
  });

  test(
      'persisted send hook and supplied committed-only stream avoid premature events',
      () async {
    final f = Fixture();
    final committed = StreamController<MessageRecord>.broadcast();
    var hookCalls = 0;
    final b = DomainOneBotBackend(f.service,
        botId: 'bot-a', messageStream: committed.stream, sendHandler: (
            {required actor, required conversationId, required parts}) async {
      hookCalls++;
      return f.service.sendMessage(
          actor: actor, conversationId: conversationId, parts: parts);
    });
    final p = OneBotProjection(backend: b);
    addTearDown(() async {
      await p.close();
      await b.close();
      await committed.close();
      await f.close();
    });
    final response = await p.handle(12, {
      'action': 'send_message',
      'params': {
        'detail_type': 'group',
        'group_id': f.roomId,
        'message': 'persisted-hook'
      }
    });
    expectOk(response);
    expect(hookCalls, 1);
    expect(
        (await p
            .handle(12, {'action': 'get_latest_events', 'params': {}}))['data'],
        isEmpty);
    committed.add(f.service.state.messages[response['data']['message_id']]!);
    await Future<void>.delayed(Duration.zero);
    expect(
        ((await p.handle(
                    12, {'action': 'get_latest_events', 'params': {}}))['data']
                as List)
            .length,
        1);
  });

  test(
      'private directResolver commits conversation before persisted message hook',
      () async {
    final f = Fixture();
    final order = <String>[];
    final b = DomainOneBotBackend(f.service, botId: 'bot-a',
        directResolver: (target) async {
      order.add('direct');
      return f.service
          .directConversation(actor: f.service.actor('bot-a'), targetId: target)
          .id;
    }, sendHandler: (
            {required actor, required conversationId, required parts}) async {
      order.add('message');
      expect(f.service.state.conversations.containsKey(conversationId), isTrue);
      return f.service.sendMessage(
          actor: actor, conversationId: conversationId, parts: parts);
    });
    final p = OneBotProjection(backend: b);
    addTearDown(() async {
      await p.close();
      await b.close();
      await f.close();
    });
    expectOk(await p.handle(12, {
      'action': 'send_message',
      'params': {
        'detail_type': 'private',
        'user_id': 'bob',
        'message': 'committed direct'
      }
    }));
    expect(order, ['direct', 'message']);
  });

  test(
      'serviceProvider follows replayed state rather than a stale service pointer',
      () async {
    final f = Fixture();
    var current = f.service;
    final commits = StreamController<MessageRecord>.broadcast();
    final b = DomainOneBotBackend(f.service,
        botId: 'bot-a',
        serviceProvider: () => current,
        messageStream: commits.stream);
    final p = OneBotProjection(backend: b);
    addTearDown(() async {
      await p.close();
      await b.close();
      await commits.close();
      if (!identical(current, f.service)) await current.close();
      await f.close();
    });
    current = ChatService(ChatState.fromJson(f.service.state.toJson()));
    current.setBotCaps(
        actor: current.actor('alice'),
        botId: 'bot-a',
        caps: {BotCapability.readHistory});
    final response = await p.handle(12, {
      'action': 'send_message',
      'params': {
        'detail_type': 'group',
        'group_id': f.roomId,
        'message': 'must fail in new state'
      }
    });
    expect(response['retcode'], 35001);
    expect(f.service.state.messages, isEmpty);
  });

  test(
      'after-leave list hides unjoined groups but old get_msg remains and future events do not leak',
      () async {
    final f = Fixture();
    addTearDown(f.close);
    final old =
        f.service.sendMessage(actor: f.bob, conversationId: f.roomId, parts: [
      {
        'type': 'text',
        'data': {'text': 'before leave'}
      }
    ]);
    await Future<void>.delayed(Duration.zero);
    await f.call(12, 'get_latest_events');
    f.service.leaveSpace(actor: f.alice, spaceId: 'space', botId: 'bot-a');
    final future =
        f.service.sendMessage(actor: f.bob, conversationId: f.roomId, parts: [
      {
        'type': 'text',
        'data': {'text': 'after leave same timestamp'}
      }
    ]);
    await Future<void>.delayed(Duration.zero);
    expect((await f.call(12, 'get_group_list'))['data'], isEmpty);
    expect((await f.call(12, 'get_guild_list'))['data'], isEmpty);
    expect((await f.call(12, 'get_latest_events'))['data'], isEmpty);
    expectOk(await f.call(11, 'get_msg',
        {'message_id': f.projection.ids.encode('message', old.id)}));
    expect(
        (await f.call(11, 'get_msg', {
          'message_id': f.projection.ids.encode('message', future.id)
        }))['status'],
        'failed');
  });

  test('concurrent poll is rejected; close wakes pending long poll', () async {
    final f = Fixture();
    addTearDown(f.close);
    final pending = f.call(12, 'get_latest_events', {'timeout': 10});
    final concurrent = await f.call(12, 'get_latest_events');
    expect(concurrent['retcode'], 35004);
    await f.projection.close();
    expectOk(await pending.timeout(const Duration(seconds: 1)));
  });

  test('bounded event queue exposes loss and does not claim reliable replay',
      () async {
    final f = Fixture(eventBufferSize: 2);
    addTearDown(f.close);
    for (var i = 0; i < 4; i++) {
      f.service.sendMessage(actor: f.bob, conversationId: f.roomId, parts: [
        {
          'type': 'text',
          'data': {'text': '$i'}
        }
      ]);
    }
    await Future<void>.delayed(Duration.zero);
    expect(f.projection.droppedEvents, 2);
    final events = (await f.call(12, 'get_latest_events'))['data'] as List;
    expect(events.length, 2);
    expect(events.first['message'].single['data']['text'], '2');
  });
}
