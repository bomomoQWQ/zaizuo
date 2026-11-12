import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';
import 'package:zaizuo_onebot/zaizuo_onebot.dart';

import 'helpers.dart';

void prepareSocial(Fixture f) {
  f.service.configureCommunity(
      actor: f.alice,
      config: CommunityConfig(botPostsPerHour: 0, botMessagesPerHour: 0));
  f.service.createRoom(
      actor: f.alice,
      spaceId: 'space',
      id: 'forum',
      title: 'Native forum',
      kind: 'forum');
}

void main() {
  for (final version in [11, 12]) {
    group('v$version native social extensions', () {
      late Fixture f;
      setUp(() {
        f = Fixture();
        prepareSocial(f);
      });
      tearDown(() => f.close());

      test(
          'forum publish/reply/query returns complete native JSON with seconds and original bot',
          () async {
        final posted = await f.call(
            version,
            'zaizuo.post_forum',
            {
              'room_id': 'forum',
              'title': 'Topic',
              'message':
                  version == 11 ? 'first &#91;post&#93;' : 'first [post]',
              'idempotency_key': 'topic-one',
            },
            version == 11
                ? {
                    'social': [1, true]
                  }
                : 'social');
        expectOk(posted);
        final post = posted['data'] as Map;
        expect(post['post_id'], isA<String>());
        expect(post['room_id'], 'forum');
        expect(post['author_id'], 'bot-a');
        expect(post['title'], 'Topic');
        expect(post['time'], fixedTime / 1000);
        expect(post['message'].single['data']['text'], 'first [post]');
        final reply = await f.call(version, 'zaizuo.reply_forum', {
          'post_id': post['post_id'],
          'message': 'bot reply',
        });
        expectOk(reply);
        expect(reply['data']['post_id'], post['post_id']);
        expect(reply['data']['user_id'], 'bot-a');
        expect(reply['data']['conversation_id'], post['conversation_id']);
        final listed =
            await f.call(version, 'zaizuo.get_posts', {'room_id': 'forum'});
        expectOk(listed);
        final read = (listed['data'] as List).single;
        expect(read['message'].single['data']['text'], 'first [post]');
        expect(read['replies'].single['message'].single['data']['text'],
            'bot reply');
        expect(
            f.service.state.messages.values
                .every((value) => value.senderId == 'bot-a'),
            isTrue);
        final retried = await f.call(version, 'zaizuo.post_forum', {
          'room_id': 'forum',
          'title': 'Topic',
          'message': version == 11 ? 'first &#91;post&#93;' : 'first [post]',
          'idempotency_key': 'topic-one',
        });
        expectOk(retried);
        expect(retried['data']['post_id'], post['post_id']);
        expect(f.service.state.forumPosts, hasLength(1));
      });

      test(
          'feed publish/comment/like/unlike/query enforce public/friends/private visibility',
          () async {
        f.service.registerAccount(
            id: 'outsider', name: 'outsider', displayName: 'Outsider');
        final outside = f.service.actor('outsider');
        final public =
            f.service.publishFeed(actor: outside, visibility: 'public', parts: [
          {
            'type': 'text',
            'data': {'text': 'public'}
          }
        ]);
        final friends =
            f.service.publishFeed(actor: f.bob, visibility: 'friends', parts: [
          {
            'type': 'text',
            'data': {'text': 'friend-only'}
          }
        ]);
        final private =
            f.service.publishFeed(actor: f.bob, visibility: 'private', parts: [
          {
            'type': 'text',
            'data': {'text': 'private-secret'}
          }
        ]);
        final strangerFriends = f.service
            .publishFeed(actor: outside, visibility: 'friends', parts: [
          {
            'type': 'text',
            'data': {'text': 'not-your-friend'}
          }
        ]);
        final list = await f.call(version, 'zaizuo.get_feed');
        expectOk(list);
        final ids = (list['data'] as List).map((post) => post['post_id']);
        expect(ids, containsAll([public.id, friends.id]));
        expect(ids, isNot(contains(private.id)));
        expect(ids, isNot(contains(strangerFriends.id)));
        expect(
            (await f.call(version, 'zaizuo.get_feed', {'post_id': private.id}))[
                'retcode'],
            version == 11 ? 1403 : 35001);
        for (final action in ['zaizuo.comment_feed', 'zaizuo.like_feed']) {
          final denied = await f.call(version, action, {
            'post_id': private.id,
            if (action == 'zaizuo.comment_feed') 'message': 'no leak'
          });
          expect(denied['retcode'], version == 11 ? 1403 : 35001);
        }
        final own = await f.call(version, 'zaizuo.post_feed',
            {'message': 'my private feed', 'visibility': 'private'});
        expectOk(own);
        expect(own['data']['author_id'], 'bot-a');
        expect(own['data']['visibility'], 'private');
        expect(own['data']['time'], fixedTime / 1000);
        final comment = await f.call(version, 'zaizuo.comment_feed',
            {'post_id': friends.id, 'message': 'comment'});
        expectOk(comment);
        expect(comment['data']['author_id'], 'bot-a');
        final like =
            await f.call(version, 'zaizuo.like_feed', {'post_id': friends.id});
        expectOk(like);
        expect(like['data']['user_id'], 'bot-a');
        final detail =
            await f.call(version, 'zaizuo.get_feed', {'post_id': friends.id});
        expectOk(detail);
        expect(
            detail['data'].single['comments'].single['message'].single['data']
                ['text'],
            'comment');
        expect(detail['data'].single['likes'], ['bot-a']);
        expectOk(await f.call(version, 'zaizuo.like_feed',
            {'post_id': friends.id, 'liked': false}));
        expect(
            f.service
                .feedLikes(actor: f.service.actor('bot-a'), postId: friends.id),
            isEmpty);
        expect(
            (await f.call(
                version, 'zaizuo.get_feed', {'author_id': 'bot-a'}))['data'],
            hasLength(1));
      });

      test(
          'social fields/action whitelist rejects sender override, bad paging and unsupported media',
          () async {
        for (final field in [
          'actor',
          'actor_id',
          'bot_id',
          'sender_id',
          'url',
          'parts'
        ]) {
          final result = await f.call(version, 'zaizuo.post_feed',
              {'message': 'must not publish', field: 'bot-b'});
          expect(result['status'], 'failed');
          expect(result['retcode'], version == 11 ? 1400 : 10004);
        }
        expect(f.service.state.feedPosts, isEmpty);
        final unknown = await f.call(version, 'zaizuo.delete_feed', {});
        expect(unknown['retcode'], version == 11 ? 1404 : 10002);
        expect(
            (await f.call(version, 'zaizuo.get_posts',
                {'room_id': 'forum', 'limit': 101}))['status'],
            'failed');
        expect(
            (await f.call(version, 'zaizuo.get_feed',
                {'post_id': 'x', 'author_id': 'bob'}))['status'],
            'failed');
        final media = await f.call(version, 'zaizuo.post_feed', {
          'message': [
            {
              'type': 'image',
              'data': {'file_id': 'local-file-only'}
            }
          ]
        });
        expect(media['retcode'], version == 11 ? 1400 : 10005);
        expect(f.service.state.feedPosts, isEmpty);
      });

      test(
          'forum room permissions and retired bot/capability cannot use social commands',
          () async {
        f.service.configureRoom(
            actor: f.alice,
            roomId: 'forum',
            config: RoomConfig(allowedPrincipalIds: {'alice', 'bob'}));
        expect(
            (await f.call(version, 'zaizuo.post_forum', {
              'room_id': 'forum',
              'title': 'denied',
              'message': 'denied'
            }))['retcode'],
            version == 11 ? 1403 : 35001);
        f.service.setBotCaps(
            actor: f.alice, botId: 'bot-a', caps: {BotCapability.readHistory});
        expect(
            (await f.call(
                version, 'zaizuo.post_feed', {'message': 'denied'}))['retcode'],
            version == 11 ? 1403 : 35001);
        expect(f.service.state.feedPosts, isEmpty);
      });
    });
  }

  test(
      'social capabilities advertised truthfully without pretending standard actions',
      () async {
    final f = Fixture();
    addTearDown(f.close);
    final supported =
        (await f.call(12, 'get_supported_actions'))['data'] as List;
    expect(supported, containsAll(OneBotProjection.socialActions));
    expect(supported, isNot(contains('post_forum')));
    final v11 = (await f.call(11, 'get_version_info'))['data'];
    expect(v11['zaizuo.supported_actions'], contains('zaizuo.post_feed'));
    final core = OneBotProjection(backend: CoreOnlyBackend(f.backend));
    addTearDown(core.close);
    final coreActions = (await core.handle(
        12, {'action': 'get_supported_actions', 'params': {}}))['data'] as List;
    expect(coreActions, isNot(contains('zaizuo.post_feed')));
    expect(
        (await core.handle(12, {
          'action': 'zaizuo.post_feed',
          'params': {'message': 'x'}
        }))['retcode'],
        10002);
  });

  test(
      'runtime commandHandler receives only whitelist params and readback keeps fixed bot',
      () async {
    final f = Fixture();
    prepareSocial(f);
    final calls = <(String, Map<String, dynamic>)>[];
    final backend = DomainOneBotBackend(f.service, botId: 'bot-a',
        commandHandler: (op, p) async {
      calls.add((op, {...p}));
      final actor = f.service.actor('bot-a');
      switch (op) {
        case 'forum.post':
          return f.service
              .createForumPost(
                  actor: actor,
                  roomId: p['room'] as String,
                  title: p['title'] as String,
                  parts: (p['parts'] as List).cast<Map<String, dynamic>>(),
                  idempotencyKey: p['idempotency_key'] as String?)
              .toJson();
        case 'forum.reply':
          return f.service
              .replyForumPost(
                  actor: actor,
                  postId: p['post'] as String,
                  parts: (p['parts'] as List).cast<Map<String, dynamic>>())
              .toJson();
        case 'feed.post':
          return f.service
              .publishFeed(
                  actor: actor,
                  visibility: p['visibility'] as String,
                  parts: (p['parts'] as List).cast<Map<String, dynamic>>())
              .toJson();
        case 'feed.comment':
          return f.service
              .commentFeed(
                  actor: actor,
                  postId: p['post'] as String,
                  parts: (p['parts'] as List).cast<Map<String, dynamic>>())
              .toJson();
        case 'feed.like':
          f.service.likeFeed(
              actor: actor,
              postId: p['post'] as String,
              liked: p['liked'] as bool);
          return {};
        default:
          throw StateError('Unexpected command');
      }
    });
    final p = OneBotProjection(backend: backend);
    addTearDown(() async {
      await p.close();
      await backend.close();
      await f.close();
    });
    Future<Map<String, dynamic>> action(
            String action, Map<String, dynamic> params) =>
        p.handle(12, {'action': 'zaizuo.$action', 'params': params});
    final topic = await action('post_forum', {
      'room_id': 'forum',
      'title': 'runtime',
      'message': 'posted',
      'idempotency_key': 'runtime-topic'
    });
    expectOk(topic);
    expectOk(await action('reply_forum',
        {'post_id': topic['data']['post_id'], 'message': 'reply'}));
    final feed =
        await action('post_feed', {'visibility': 'private', 'message': 'feed'});
    expectOk(feed);
    expectOk(await action('comment_feed',
        {'post_id': feed['data']['post_id'], 'message': 'comment'}));
    expectOk(await action('like_feed', {'post_id': feed['data']['post_id']}));
    expect(calls.map((value) => value.$1), [
      'forum.post',
      'forum.reply',
      'feed.post',
      'feed.comment',
      'feed.like'
    ]);
    expect(calls.first.$2.keys.toSet(),
        {'room', 'title', 'parts', 'idempotency_key'});
    expect(calls.last.$2.keys.toSet(), {'post', 'liked'});
    expect(calls.expand((value) => value.$2.keys), isNot(contains('actor')));
  });

  test(
      'post-only bot receives its own write receipt without history-read side effects',
      () async {
    final f = Fixture();
    prepareSocial(f);
    addTearDown(f.close);
    f.service.setBotCaps(
        actor: f.alice,
        botId: 'bot-a',
        caps: {BotCapability.post, BotCapability.sendMessage});
    expectOk(await f.call(12, 'zaizuo.post_forum',
        {'room_id': 'forum', 'title': 'write-only', 'message': 'own receipt'}));
    expectOk(await f.call(11, 'zaizuo.post_feed', {'message': 'own feed'}));
    expect(
        (await f.call(12, 'zaizuo.get_posts', {'room_id': 'forum'}))['retcode'],
        35001);
    expect((await f.call(11, 'zaizuo.get_feed'))['retcode'], 1403);
    expect(f.service.state.forumPosts, hasLength(1));
    expect(f.service.state.feedPosts, hasLength(1));
  });

  test('social commandHandler persistence errors never produce fake success',
      () async {
    final f = Fixture();
    prepareSocial(f);
    final b = DomainOneBotBackend(f.service,
        botId: 'bot-a',
        commandHandler: (op, params) async => throw const DomainException(
            'forbidden', 'simulated denied commit'));
    final p = OneBotProjection(backend: b);
    addTearDown(() async {
      await p.close();
      await b.close();
      await f.close();
    });
    final result = await p.handle(12, {
      'action': 'zaizuo.post_feed',
      'params': {'message': 'not committed'},
      'echo': 'failure'
    });
    expect(result['retcode'], 35001);
    expect(result['echo'], 'failure');
    expect(f.service.state.feedPosts, isEmpty);
  });

  test(
      'social hook cannot substitute another author or forge a committed record',
      () async {
    final f = Fixture();
    prepareSocial(f);
    final bobPost = f.service.publishFeed(actor: f.bob, parts: [
      {
        'type': 'text',
        'data': {'text': 'not bot'}
      }
    ]);
    final b = DomainOneBotBackend(f.service,
        botId: 'bot-a', commandHandler: (op, params) => bobPost.toJson());
    final p = OneBotProjection(backend: b);
    addTearDown(() async {
      await p.close();
      await b.close();
      await f.close();
    });
    final result = await p.handle(12, {
      'action': 'zaizuo.post_feed',
      'params': {'message': 'forged'}
    });
    expect(result['retcode'], 35001);
    expect(f.service.state.feedPosts, hasLength(1));
  });

  test(
      'social paging and hidden post/comment filters use domain-authorized lists',
      () async {
    final f = Fixture();
    prepareSocial(f);
    addTearDown(f.close);
    final first = await f.call(12, 'zaizuo.post_forum',
        {'room_id': 'forum', 'title': 'first', 'message': '1'});
    final second = await f.call(12, 'zaizuo.post_forum',
        {'room_id': 'forum', 'title': 'second', 'message': '2'});
    final page = await f.call(12, 'zaizuo.get_posts', {
      'room_id': 'forum',
      'before_id': second['data']['post_id'],
      'limit': 1
    });
    expect(page['data'].single['post_id'], first['data']['post_id']);
    f.service.hideContent(
        actor: f.alice,
        kind: 'forum',
        contentId: first['data']['post_id'] as String);
    expect((await f.call(12, 'zaizuo.get_posts', {'room_id': 'forum'}))['data'],
        hasLength(1));
    final feed = await f.call(12, 'zaizuo.post_feed', {'message': 'feed'});
    final comment = await f.call(12, 'zaizuo.comment_feed',
        {'post_id': feed['data']['post_id'], 'message': 'hide me'});
    f.service.hideContent(
        actor: f.alice,
        kind: 'comment',
        contentId: comment['data']['comment_id'] as String);
    final detail = await f
        .call(12, 'zaizuo.get_feed', {'post_id': feed['data']['post_id']});
    expect(detail['data'].single['comments'], isEmpty);
  });

  test(
      'HTTP v11/v12 social actions use same fixed domain bot and authorization',
      () async {
    final f = Fixture();
    prepareSocial(f);
    final server = OneBotServer(
        bindings: [OneBotBinding(token: token, projection: f.projection)]);
    await server.start();
    addTearDown(() async {
      await server.close();
      await f.close();
    });
    final a = await httpCall(server.port, '/onebot/v11/zaizuo.post_forum', {
      'room_id': 'forum',
      'title': 'HTTP topic',
      'message': 'HTTP11',
      'echo': {'v': 11}
    });
    expectOk(a.json);
    expect(a.json['echo'], {'v': 11});
    final b = await httpCall(server.port, '/onebot/v12', {
      'action': 'zaizuo.reply_forum',
      'params': {'post_id': a.json['data']['post_id'], 'message': 'HTTP12'},
      'echo': 'v12'
    });
    expectOk(b.json);
    expect(b.json['data']['user_id'], 'bot-a');
    final denied = await httpCall(server.port, '/onebot/v12', {
      'action': 'zaizuo.post_feed',
      'params': {'message': 'blocked'},
      'self': {'platform': 'zaizuo', 'user_id': 'bot-b'}
    });
    expect(denied.json['retcode'], 10102);
    expect(f.service.state.feedPosts, isEmpty);
  });

  for (final version in [11, 12]) {
    test(
        'reverse v$version WS dispatches native social extension without identity override',
        () async {
      final f = Fixture();
      prepareSocial(f);
      final remote = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<WebSocket>();
      remote.listen((request) async {
        final ws = await WebSocketTransformer.upgrade(request,
            compression: CompressionOptions.compressionOff);
        if (!accepted.isCompleted) accepted.complete(ws);
      });
      final url = Uri.parse('ws://127.0.0.1:${remote.port}/social');
      final reverse = OneBotReverseClient(
          projection: f.projection,
          config: ReverseWebSocketConfig(
              url: url,
              version: version,
              token: token,
              trustedUrls: {url},
              enabled: true));
      reverse.start();
      final ws = await accepted.future.timeout(const Duration(seconds: 3));
      final inbox = WsInbox(ws);
      addTearDown(() async {
        await reverse.close();
        await inbox.close();
        await ws.close();
        await remote.close(force: true);
        await f.close();
      });
      ws.add(jsonEncode({
        'action': 'zaizuo.post_feed',
        'params': {'message': 'reverse social', 'visibility': 'private'},
        'echo': 'native'
      }));
      final response = await inbox.next((value) => value['echo'] == 'native');
      expectOk(response);
      expect(response['data']['author_id'], 'bot-a');
      expect(response['data']['time'], fixedTime / 1000);
      expect(f.service.state.feedPosts.values.single.authorId, 'bot-a');
    });
  }
}

class CoreOnlyBackend implements OneBotBackend {
  CoreOnlyBackend(this.inner);
  final OneBotBackend inner;
  @override
  String get botId => inner.botId;
  @override
  Stream<BotMessage> get messages => inner.messages;
  @override
  FutureOr<BotProfile> getSelf() => inner.getSelf();
  @override
  FutureOr<BotProfile> getUser(String id) => inner.getUser(id);
  @override
  FutureOr<List<BotProfile>> getFriends() => inner.getFriends();
  @override
  FutureOr<List<BotGroup>> getGroups() => inner.getGroups();
  @override
  FutureOr<BotGroup> getGroup(String id) => inner.getGroup(id);
  @override
  FutureOr<List<BotProfile>> getGroupMembers(String id) =>
      inner.getGroupMembers(id);
  @override
  FutureOr<BotMessage> getMessage(String id) => inner.getMessage(id);
  @override
  FutureOr<bool> isOnline() => inner.isOnline();
  @override
  FutureOr<BotMessage> send(
          {required String detailType,
          required String targetId,
          required List<Map<String, dynamic>> parts}) =>
      inner.send(detailType: detailType, targetId: targetId, parts: parts);
}
