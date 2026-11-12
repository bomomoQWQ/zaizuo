import 'dart:convert';

import 'package:test/test.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';
import 'package:zaizuo_runtime/src/commands.dart';

List<JsonMap> text(String value) => [
      {
        'type': 'text',
        'data': {'text': value}
      }
    ];
Matcher domainError(String code) =>
    isA<DomainException>().having((error) => error.code, 'code', code);
const operations = {
  'message.send',
  'bot.register',
  'bot.draft',
  'bot.admit',
  'bot.retire',
  'bot.caps',
  'community.configure',
  'space.create',
  'space.configure',
  'room.create',
  'room.configure',
  'space.admin',
  'space.invite',
  'space.join',
  'space.leave',
  'space.decide',
  'space.kick',
  'space.ban',
  'space.mute',
  'friend.add',
  'friend.remove',
  'direct.create',
  'direct.permission',
  'direct.renew',
  'forum.post',
  'forum.reply',
  'feed.post',
  'feed.comment',
  'feed.like',
  'content.hide',
};

final class Fixture {
  DateTime time = DateTime.utc(2026, 1, 1);
  late final ChatService service;
  Fixture() {
    service =
        ChatService(ChatState(communityOwnerId: 'alice'), now: () => time);
    for (final id in ['alice', 'bob', 'carol']) {
      service.registerAccount(id: id, name: id, displayName: id);
    }
  }
  Object? run(String actor, String operation, JsonMap params) =>
      applyCommand(service, actor, operation, params);
  SpaceRecord space({bool public = true, JsonMap? config}) =>
      run('alice', 'space.create', {
        'id': 'space',
        'title': '空间',
        'public_channel': public,
        if (config != null) 'config': config
      }) as SpaceRecord;
  BotRecord bot(String actor, String id) =>
      run(actor, 'bot.register', {'id': id, 'display_name': id}) as BotRecord;
  void join(String actor, {String? botId}) => run(actor, 'space.join',
      {'space': 'space', if (botId != null) 'bot_id': botId});
}

void main() {
  test('白名单覆盖全部30个业务写操作，账号注册不能来自命令日志', () {
    final f = Fixture();
    expect(operations.length, 30);
    for (final op in [
      ...operations,
      'account.register',
      'state.patch',
      'actor',
      'close',
      'MESSAGE.SEND',
      'unknown'
    ]) {
      final before = jsonEncode(f.service.state.toJson());
      expect(() => f.run('alice', op, {'actor': 'bob'}),
          throwsA(domainError('bad_request')),
          reason: op);
      expect(jsonEncode(f.service.state.toJson()), before, reason: op);
    }
    expect(
        () => f.run('alice', 'account.register',
            {'id': 'mallory', 'name': 'mallory', 'display_name': 'm'}),
        throwsA(domainError('bad_request')));
    expect(f.service.state.accounts.keys, ['alice', 'bob', 'carol']);
  });

  test('任何op的未知或身份覆盖参数都拒绝，不读取params自报owner/self', () {
    final f = Fixture();
    for (final op in operations) {
      for (final field in [
        'actor',
        'actorId',
        'ownerId',
        'principalId',
        'self',
        'unknown',
        'idempotencyKey'
      ]) {
        expect(() => f.run('alice', op, {field: 'alice'}),
            throwsA(domainError('bad_request')),
            reason: '$op:$field');
      }
    }
    final bot = f.bot('alice', 'bot');
    expect(
        () => f.run(bot.id, 'space.create',
            {'id': 'illegal', 'title': 'x', 'public_channel': true}),
        throwsA(domainError('forbidden')));
    expect(() => f.run('missing', 'feed.post', {'parts': text('x')}),
        throwsA(domainError('not_found')));
  });

  test('全部命令缺少required参数均返回业务bad_request而不是强转TypeError', () {
    final f = Fixture();
    for (final op in operations) {
      expect(() => f.run('alice', op, {}), throwsA(domainError('bad_request')),
          reason: op);
    }
  });

  test('机器人草案/入驻/能力/退驻/复活均通过命令且不改变owner', () {
    final f = Fixture();
    final draft =
        f.run('alice', 'bot.draft', {'id': 'bot', 'display_name': '小在'})
            as BotRecord;
    expect(draft.draft, isTrue);
    expect(draft.active, isFalse);
    expect(() => f.run('bob', 'bot.admit', {'bot_id': draft.id}),
        throwsA(domainError('forbidden')));
    final admitted =
        f.run('alice', 'bot.admit', {'bot_id': draft.id}) as BotRecord;
    expect(admitted.active, isTrue);
    expect(admitted.ownerId, 'alice');
    final updated = f.run('alice', 'bot.caps', {
      'bot_id': draft.id,
      'caps': ['history.read']
    }) as BotRecord;
    expect(updated.caps, {'history.read'});
    expect(
        () => f.run('alice', 'bot.caps', {
              'bot_id': draft.id,
              'caps': ['space.join']
            }),
        throwsA(domainError('bad_request')));
    expect(
        (f.run('alice', 'bot.retire', {'bot_id': draft.id}) as BotRecord)
            .active,
        isFalse);
    expect((f.run('alice', 'bot.admit', {'bot_id': draft.id}) as BotRecord).id,
        draft.id);
    expect(f.bot('bob', 'b').ownerId, 'bob');
  });

  test('community配置所有字段可写、仅owner、替换不是patch、0不限', () {
    final f = Fixture();
    final config = CommunityConfig(
        maxAccounts: 10,
        maxBots: 20,
        maxSpaces: 30,
        maxBotsPerOwner: 0,
        maxSpacesPerOwner: 5,
        botMessagesPerHour: 7,
        botPostsPerHour: 8,
        botDirectsPerHour: 9,
        maxDirectMessages: 10);
    expect(
        () => f.run('bob', 'community.configure', {'config': config.toJson()}),
        throwsA(domainError('forbidden')));
    f.run('alice', 'community.configure', {'config': config.toJson()});
    expect(f.service.state.config.toJson(), config.toJson());
    f.run('alice', 'community.configure', {
      'config': {'maxBotsPerOwner': 0}
    });
    expect(f.service.state.config.maxBotsPerOwner, 0);
    expect(f.service.state.config.botMessagesPerHour, 120);
    for (var i = 0; i < 7; i++) {
      f.bot('alice', 'bot$i');
    }
    expect(f.service.state.bots.length, 7);
  });

  test('space.create可选默认房间配置/编号/幂等，space/room配置字段完整', () {
    final f = Fixture();
    final config = SpaceConfig(
        maxMembers: 12,
        maxBots: 3,
        maxBotsPerOwner: 1,
        maxRooms: 3,
        allowBots: true,
        allowBotMessages: false,
        allowBotDirects: false,
        historyVisibleToNewMembers: true,
        slowModeMs: 10);
    final roomConfig = RoomConfig(
        allowedPrincipalIds: {'alice'},
        readOnly: true,
        allowBotMessages: false,
        messagesPerHour: 7,
        postsPerHour: 3,
        slowModeMs: 20);
    final params = {
      'id': 'space',
      'title': '空间',
      'public_channel': true,
      'config': config.toJson(),
      'default_room_config': roomConfig.toJson(),
      'default_room_id': 'custom-main',
      'idempotency_key': 'space-once'
    };
    final space = f.run('alice', 'space.create', params) as SpaceRecord;
    expect(space.config.toJson(), config.toJson());
    expect(space.defaultRoomId, 'custom-main');
    expect(f.service.state.rooms[space.defaultRoomId]!.config.toJson(),
        roomConfig.toJson());
    expect(
        (f.run('alice', 'space.create', params) as SpaceRecord).id, space.id);
    final newConfig =
        SpaceConfig(maxRooms: 5, historyVisibleToNewMembers: false);
    f.run('alice', 'space.configure',
        {'space': space.id, 'config': newConfig.toJson()});
    expect(
        f.service.state.spaces[space.id]!.config.toJson(), newConfig.toJson());
    f.run('alice', 'room.configure', {
      'room': space.defaultRoomId,
      'config': {'readOnly': false}
    });
    expect(
        f.service.state.rooms[space.defaultRoomId]!.config.readOnly, isFalse);
    final chat = f.run('alice', 'room.create', {
      'space': space.id,
      'id': 'chat2',
      'title': '茶室',
      'config': roomConfig.toJson(),
      'idempotency_key': 'room-once'
    }) as RoomRecord;
    expect(chat.kind, 'chat');
    expect(chat.shadowConversationId, 'chat2#shadow');
    final forum = f.run('alice', 'room.create', {
      'space': space.id,
      'id': 'forum',
      'title': '论坛',
      'kind': 'forum'
    }) as RoomRecord;
    expect(forum.kind, 'forum');
    expect(forum.shadowConversationId, isNull);
  });

  test('私域真实邀请/申请审批/拒绝，邀请标记不能作为通行证', () {
    final f = Fixture();
    f.space(public: false);
    f.bot('bob', 'bot');
    expect(
        () => f.run('bob', 'space.join', {'space': 'space', 'invited': true}),
        throwsA(domainError('forbidden')));
    f.run('alice', 'space.invite', {'space': 'space', 'principal': 'bot'});
    final membership = f.run('bob', 'space.join', {
      'space': 'space',
      'bot_id': 'bot',
      'invited': true,
      'idempotency_key': 'join-once'
    }) as MembershipRecord;
    expect(membership.status, 'joined');
    final pending =
        f.run('bob', 'space.join', {'space': 'space'}) as MembershipRecord;
    expect(pending.status, 'pending');
    f.run('alice', 'space.decide',
        {'space': 'space', 'principal': 'bob', 'approve': true});
    f.run('carol', 'space.join', {'space': 'space'});
    f.run('alice', 'space.decide',
        {'space': 'space', 'principal': 'carol', 'approve': false});
    expect(
        f.service
            .members(actor: f.service.actor('alice'), spaceId: 'space')
            .map((p) => p.id),
        containsAll(['alice', 'bot', 'bob']));
    expect(() => f.run('bot', 'space.leave', {'space': 'space'}),
        throwsA(domainError('forbidden')));
    f.run('bob', 'space.leave', {'space': 'space', 'bot_id': 'bot'});
    expect(
        f.service
            .members(actor: f.service.actor('alice'), spaceId: 'space')
            .map((p) => p.id),
        isNot(contains('bot')));
  });

  test('频道不审批、角色设定、kick、ban/unban命令执行真实领域约束', () {
    final f = Fixture();
    f.space();
    f.join('bob');
    f.join('carol');
    expect(
        () => f.run('alice', 'space.decide',
            {'space': 'space', 'principal': 'bob', 'approve': true}),
        throwsA(domainError('forbidden')));
    f.run('alice', 'space.admin',
        {'space': 'space', 'account_id': 'bob', 'enabled': true});
    expect(f.service.state.spaces['space']!.adminIds, {'bob'});
    f.run('bob', 'space.kick', {'space': 'space', 'principal': 'carol'});
    f.join('carol');
    f.run('alice', 'space.admin',
        {'space': 'space', 'account_id': 'bob', 'enabled': false});
    expect(
        () => f
            .run('bob', 'space.kick', {'space': 'space', 'principal': 'carol'}),
        throwsA(domainError('forbidden')));
    f.run('alice', 'space.ban',
        {'space': 'space', 'principal': 'carol', 'banned': true});
    expect(() => f.join('carol'), throwsA(domainError('forbidden')));
    f.run('alice', 'space.ban',
        {'space': 'space', 'principal': 'carol', 'banned': false});
    f.join('carol');
  });

  test('房间ban和空间/房间mute时间、取消参数完整传递', () {
    final f = Fixture();
    final space = f.space();
    f.join('bob');
    final until = f.time.millisecondsSinceEpoch + 1000;
    f.run('alice', 'space.mute',
        {'space': 'space', 'principal': 'bob', 'until_ms': until});
    expect(
        () => f.run('bob', 'message.send',
            {'conversation': space.defaultRoomId, 'parts': text('muted')}),
        throwsA(domainError('forbidden')));
    f.time = f.time.add(const Duration(seconds: 1));
    f.run('bob', 'message.send',
        {'conversation': space.defaultRoomId, 'parts': text('after')});
    f.run('alice', 'space.mute',
        {'space': 'space', 'principal': 'bob', 'room': space.defaultRoomId});
    expect(
        () => f.run('bob', 'message.send',
            {'conversation': space.defaultRoomId, 'parts': text('forever')}),
        throwsA(domainError('forbidden')));
    f.run('alice', 'space.mute', {
      'space': 'space',
      'principal': 'bob',
      'room': space.defaultRoomId,
      'muted': false,
      'until_ms': null
    });
    f.run('bob', 'message.send',
        {'conversation': space.defaultRoomId, 'parts': text('unmuted')});
    f.run('alice', 'space.ban', {
      'space': 'space',
      'principal': 'bob',
      'room': space.defaultRoomId,
      'banned': true
    });
    expect(
        () => f.run('bob', 'message.send',
            {'conversation': space.defaultRoomId, 'parts': text('banned')}),
        throwsA(domainError('forbidden')));
  });

  test('好友和人DM、idempotency_key贯穿创建与发送，删好友停止新写保历史', () {
    final f = Fixture();
    f.run('alice', 'friend.add',
        {'target': 'bob', 'idempotency_key': 'friend-once'});
    final dm = f.run('alice', 'direct.create',
        {'target': 'bob', 'idempotency_key': 'dm-once'}) as ConversationRecord;
    expect(
        (f.run('bob', 'direct.create', {'target': 'alice'})
                as ConversationRecord)
            .id,
        dm.id);
    final p = {
      'conversation': dm.id,
      'parts': text('hello'),
      'idempotency_key': 'msg-once'
    };
    final message = f.run('alice', 'message.send', p) as MessageRecord;
    expect((f.run('alice', 'message.send', p) as MessageRecord).toJson(),
        message.toJson());
    expect(
        () =>
            f.run('alice', 'message.send', {...p, 'parts': text('different')}),
        throwsA(domainError('idempotency_conflict')));
    f.run('alice', 'friend.remove',
        {'target': 'bob', 'idempotency_key': 'remove-once'});
    expect(
        () => f.run('bob', 'message.send',
            {'conversation': dm.id, 'parts': text('future')}),
        throwsA(domainError('forbidden')));
    expect(
        f.service
            .message(actor: f.service.actor('bob'), messageId: message.id)
            .id,
        message.id);
  });

  test('owner可用bot_id管理好友，不授予bot自身社交入口', () {
    final f = Fixture();
    f.bot('alice', 'bot');
    f.run('alice', 'friend.add', {'target': 'bob', 'bot_id': 'bot'});
    expect(f.service.friends(actor: f.service.actor('bot')).map((p) => p.id),
        contains('bob'));
    f.run('alice', 'friend.remove', {'target': 'bob', 'bot_id': 'bot'});
    expect(f.service.friends(actor: f.service.actor('bot')).map((p) => p.id),
        isNot(contains('bob')));
    expect(() => f.run('bot', 'friend.add', {'target': 'bob'}),
        throwsA(domainError('forbidden')));
  });

  test('bot-bot双owner显式许可/撤销/续期最大次数，owner仍只读', () {
    final f = Fixture();
    f.bot('alice', 'a');
    f.bot('bob', 'b');
    f.run('alice', 'community.configure', {
      'config': {'maxDirectMessages': 1}
    });
    final expires = f.time.millisecondsSinceEpoch + 10000;
    f.run('alice', 'direct.permission',
        {'bot_id': 'a', 'target_bot_id': 'b', 'until_ms': expires});
    expect(() => f.run('a', 'direct.create', {'target': 'b'}),
        throwsA(domainError('forbidden')));
    f.run('bob', 'direct.permission', {'bot_id': 'b', 'target_bot_id': 'a'});
    final dm =
        f.run('a', 'direct.create', {'target': 'b'}) as ConversationRecord;
    f.run('a', 'message.send', {'conversation': dm.id, 'parts': text('one')});
    expect(
        () => f.run(
            'b', 'message.send', {'conversation': dm.id, 'parts': text('two')}),
        throwsA(domainError('rate_limited')));
    f.run('alice', 'direct.renew', {'conversation': dm.id});
    expect(
        () => f.run('b', 'message.send',
            {'conversation': dm.id, 'parts': text('one vote')}),
        throwsA(domainError('rate_limited')));
    f.run('bob', 'direct.renew', {'conversation': dm.id});
    f.run('b', 'message.send', {'conversation': dm.id, 'parts': text('next')});
    expect(
        () => f.run('alice', 'message.send',
            {'conversation': dm.id, 'parts': text('owner')}),
        throwsA(domainError('forbidden')));
    f.run('alice', 'direct.permission',
        {'bot_id': 'a', 'target_bot_id': 'b', 'allow': false});
    expect(
        () => f.run('b', 'message.send',
            {'conversation': dm.id, 'parts': text('revoked')}),
        throwsA(domainError('forbidden')));
  });

  test('论坛首帖/回复和内容隐藏命令，原消息事件仍保留', () {
    final f = Fixture();
    final space = f.space();
    f.join('bob');
    final room = f.run('alice', 'room.create', {
      'space': space.id,
      'id': 'forum',
      'title': '论坛',
      'kind': 'forum'
    }) as RoomRecord;
    final post = f.run('bob', 'forum.post', {
      'room': room.id,
      'title': '帖子',
      'parts': text('post'),
      'idempotency_key': 'post-once'
    }) as ForumPostRecord;
    final reply = f.run('alice', 'forum.reply', {
      'post': post.id,
      'parts': text('reply'),
      'idempotency_key': 'reply-once'
    }) as MessageRecord;
    expect(
        f.service
            .messages(
                actor: f.service.actor('bob'),
                conversationId: post.conversationId)
            .map((m) => m.id),
        [post.messageId, reply.id]);
    f.run('alice', 'content.hide', {'kind': 'message', 'content_id': reply.id});
    expect(
        f.service
            .messages(
                actor: f.service.actor('bob'),
                conversationId: post.conversationId)
            .length,
        1);
    expect(f.service.state.messages.containsKey(reply.id), isTrue);
    f.run('alice', 'content.hide', {'kind': 'forum', 'content_id': post.id});
    expect(f.service.forumPosts(actor: f.service.actor('bob'), roomId: room.id),
        isEmpty);
    f.run('alice', 'content.hide',
        {'kind': 'forum', 'content_id': post.id, 'hidden': false});
    expect(
        f.service
            .forumPosts(actor: f.service.actor('bob'), roomId: room.id)
            .single
            .id,
        post.id);
  });

  test('朋友圈visibility、评论like/unlike和社区内容隐藏完整接入', () {
    final f = Fixture();
    final private = f.run('bob', 'feed.post',
        {'parts': text('private'), 'visibility': 'private'}) as FeedPostRecord;
    final friends =
        f.run('bob', 'feed.post', {'parts': text('friends')}) as FeedPostRecord;
    final public = f.run('bob', 'feed.post', {
      'parts': text('public'),
      'visibility': 'public',
      'idempotency_key': 'feed-once'
    }) as FeedPostRecord;
    expect(
        () => f.run('alice', 'feed.comment',
            {'post': private.id, 'parts': text('hidden')}),
        throwsA(domainError('forbidden')));
    expect(() => f.run('alice', 'feed.like', {'post': friends.id}),
        throwsA(domainError('forbidden')));
    final comment = f.run('alice', 'feed.comment', {
      'post': public.id,
      'parts': text('comment'),
      'idempotency_key': 'comment-once'
    }) as FeedCommentRecord;
    f.run('alice', 'feed.like',
        {'post': public.id, 'idempotency_key': 'like-once'});
    expect(
        f.service.feedLikes(actor: f.service.actor('bob'), postId: public.id),
        {'alice'});
    f.run('alice', 'feed.like', {'post': public.id, 'liked': false});
    expect(
        f.service.feedLikes(actor: f.service.actor('bob'), postId: public.id),
        isEmpty);
    f.run(
        'alice', 'content.hide', {'kind': 'comment', 'content_id': comment.id});
    expect(
        f.service
            .feedComments(actor: f.service.actor('bob'), postId: public.id),
        isEmpty);
    f.run('alice', 'content.hide', {'kind': 'feed', 'content_id': public.id});
    expect(f.service.state.feedPosts.containsKey(public.id), isTrue);
    expect(f.service.feed(actor: f.service.actor('alice')), isEmpty);
  });

  test('shape检查严格拒绝错误标量/类型/未知配置/范围/枚举，全部原子失败', () {
    final f = Fixture();
    f.space();
    final cases = <({String op, JsonMap params})>[
      (op: 'bot.register', params: {'id': 'x', 'display_name': true}),
      (op: 'bot.caps', params: {'bot_id': 'x', 'caps': 'msg.send'}),
      (
        op: 'bot.caps',
        params: {
          'bot_id': 'x',
          'caps': ['msg.send', 'msg.send']
        }
      ),
      (
        op: 'bot.caps',
        params: {
          'bot_id': 'x',
          'caps': [1]
        }
      ),
      (
        op: 'space.create',
        params: {'id': 's', 'title': 's', 'public_channel': 'true'}
      ),
      (op: 'space.join', params: {'space': 'space', 'bot_id': false}),
      (op: 'space.join', params: {'space': 'space', 'invited': null}),
      (
        op: 'space.decide',
        params: {'space': 'space', 'principal': 'bob', 'approve': 1}
      ),
      (
        op: 'space.mute',
        params: {'space': 'space', 'principal': 'bob', 'until_ms': -1}
      ),
      (
        op: 'space.mute',
        params: {'space': 'space', 'principal': 'bob', 'until_ms': 1.5}
      ),
      (
        op: 'space.mute',
        params: {
          'space': 'space',
          'principal': 'bob',
          'until_ms': 9007199254740992
        }
      ),
      (op: 'community.configure', params: {'config': null}),
      (
        op: 'community.configure',
        params: {
          'config': {'maxBots': -1}
        }
      ),
      (
        op: 'community.configure',
        params: {
          'config': {'maxBots': 1.0}
        }
      ),
      (
        op: 'community.configure',
        params: {
          'config': {'MAX_BOTS': 1}
        }
      ),
      (
        op: 'space.configure',
        params: {
          'space': 'space',
          'config': {'allowBots': 'true'}
        }
      ),
      (
        op: 'space.configure',
        params: {
          'space': 'space',
          'config': {'historyVisibleToNewMembers': null}
        }
      ),
      (
        op: 'room.configure',
        params: {
          'room': 'space#main',
          'config': {
            'allowedPrincipalIds': ['alice', 'alice']
          }
        }
      ),
      (
        op: 'room.configure',
        params: {
          'room': 'space#main',
          'config': {'allowedPrincipalIds': true}
        }
      ),
      (
        op: 'room.create',
        params: {'space': 'space', 'id': 'room', 'title': 'x', 'kind': 'DIRECT'}
      ),
      (op: 'feed.post', params: {'parts': text('x'), 'visibility': 'all'}),
      (op: 'content.hide', params: {'kind': 'delete', 'content_id': 'x'}),
      (
        op: 'message.send',
        params: {
          'conversation': 'space#main',
          'parts': text('x'),
          'idempotency_key': 2
        }
      ),
      (
        op: 'message.send',
        params: {
          'conversation': 'space#main',
          'parts': text('x'),
          'idempotency_key': ''
        }
      ),
      (
        op: 'direct.permission',
        params: {'bot_id': 'a', 'target_bot_id': 'b', 'allow': 'true'}
      ),
      (op: 'feed.like', params: {'post': 'x', 'liked': null}),
    ];
    for (final c in cases) {
      final before = jsonEncode(f.service.state.toJson());
      expect(() => f.run('alice', c.op, c.params),
          throwsA(domainError('bad_request')),
          reason: '${c.op}: ${c.params}');
      expect(jsonEncode(f.service.state.toJson()), before);
    }
  });

  test('消息段JSON深度/体积/字段形状检查且容许data扩展字段', () {
    final f = Fixture();
    final space = f.space();
    Object? deep = 'value';
    for (var i = 0; i < 40; i++) {
      deep = [deep];
    }
    final invalid = <Object?>[
      null,
      {},
      [],
      [null],
      [1],
      [
        {'type': 1}
      ],
      [
        {'type': 'text', 'data': []}
      ],
      [
        {
          'type': 'text',
          'data': {'x': double.nan}
        }
      ],
      [
        {'type': 'text', 'unexpected': true}
      ],
      [
        {
          'type': 'text',
          'data': {'bad': Object()}
        }
      ],
      [
        {
          'type': 'text',
          'data': {'nested': deep}
        }
      ]
    ];
    for (final parts in invalid) {
      expect(
          () => f.run('alice', 'message.send',
              {'conversation': space.defaultRoomId, 'parts': parts}),
          throwsA(domainError('bad_request')));
    }
    final sent = f.run('alice', 'message.send', {
      'conversation': space.defaultRoomId,
      'parts': [
        {
          'type': 'zaizuo.custom',
          'data': {
            'extension': true,
            'nested': [1, null, 2.5]
          }
        }
      ]
    }) as MessageRecord;
    expect(sent.parts.single['type'], 'zaizuo.custom');
  });
}
