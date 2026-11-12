import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';

List<JsonMap> text(String value) => [
      {
        'type': 'text',
        'data': {'text': value}
      }
    ];
Matcher error(String code) =>
    isA<DomainException>().having((e) => e.code, 'code', code);

final class Fixture {
  DateTime time = DateTime.utc(2026, 1, 1);
  late final ChatService service;
  late final Actor alice;
  late final Actor bob;
  late final Actor carol;
  Fixture({CommunityConfig? config}) {
    service = ChatService(ChatState(config: config), now: () => time);
    for (final id in ['alice', 'bob', 'carol']) {
      service.registerAccount(id: id, name: id, displayName: id);
    }
    alice = service.actor('alice');
    bob = service.actor('bob');
    carol = service.actor('carol');
  }
  Actor bot(Actor owner, String id) {
    service.registerBot(actor: owner, id: id, displayName: id);
    return service.actor(id);
  }

  SpaceRecord space({bool public = true, SpaceConfig? config}) =>
      service.createSpace(
          actor: alice,
          id: 'space',
          title: '空间',
          publicChannel: public,
          config: config);
  void join(Actor owner, {String? botId, String spaceId = 'space'}) =>
      service.joinSpace(actor: owner, spaceId: spaceId, botId: botId);
  void advance(Duration duration) {
    time = time.add(duration);
  }

  (Actor, Actor, ConversationRecord) botDm() {
    final a = bot(alice, 'a-bot');
    final b = bot(bob, 'b-bot');
    space();
    join(alice, botId: a.id);
    join(bob, botId: b.id);
    return (a, b, service.directConversation(actor: a, targetId: b.id));
  }
}

void main() {
  group('身份、Account 1:N bots 和配额', () {
    test('账户名规范和显示字素上限由 domain 独立强制', () {
      final service = ChatService(ChatState());
      for (final name in ['中文', 'a-b', 'a.b', 'abcdefghijklmno', '', 'a b']) {
        expect(
            () => service.registerAccount(
                id: 'bad', name: name, displayName: '名字'),
            throwsA(error('bad_request')));
      }
      expect(
          () => service.registerAccount(
              id: 'long',
              name: 'long',
              displayName: List.filled(15, '你').join()),
          throwsA(error('bad_request')));
      final family = List.filled(14, '👩‍👩‍👧‍👦').join();
      final account = service.registerAccount(
          id: 'id-readable', name: ' Ab_123 ', displayName: family);
      expect(account.name, 'ab_123');
      expect(account.displayName, family);
      expect(
          () => service.registerBot(
              actor: service.actor(account.id),
              id: 'bot',
              displayName: List.filled(15, 'e\u0301').join()),
          throwsA(error('bad_request')));
    });
    test('账户名归一化且唯一，编号跨人 bot 不能重复', () {
      final f = Fixture();
      expect(f.service.state.accounts['alice']!.name, 'alice');
      expect(
          () => f.service
              .registerAccount(id: 'x', name: 'ALICE', displayName: 'x'),
          throwsA(error('conflict')));
      expect(
          () => f.service
              .registerBot(actor: f.alice, id: 'bob', displayName: 'x'),
          throwsA(error('conflict')));
    });
    test('手工 Actor 即使仿冒存在的 owner/bot 也不能通过核心入口', () {
      final f = Fixture();
      final bot = f.bot(f.alice, 'bot');
      for (final actor in [
        const Actor(id: 'alice', ownerId: 'alice', isBot: false),
        Actor(id: bot.id, ownerId: 'alice', isBot: true),
        const Actor(id: 'alice', ownerId: 'alice', isBot: true)
      ]) {
        expect(
            () => f.service.createSpace(
                actor: actor, id: 'fake', title: 'x', publicChannel: true),
            throwsA(error('forbidden')));
        expect(
            () => f.service.friends(actor: actor), throwsA(error('forbidden')));
      }
      final other = ChatService(f.service.state);
      expect(() => other.friends(actor: f.alice), throwsA(error('forbidden')));
    });
    test('默认每 owner 5 个入驻、草案无限、无无主 bot', () {
      final f = Fixture();
      for (var i = 0; i < 20; i++) {
        f.service
            .createBotDraft(actor: f.alice, id: 'draft$i', displayName: '草案');
      }
      for (var i = 0; i < 5; i++) {
        f.service.registerBot(actor: f.alice, id: 'bot$i', displayName: '机器人');
      }
      expect(
          () => f.service
              .registerBot(actor: f.alice, id: 'sixth', displayName: 'x'),
          throwsA(error('quota_exceeded')));
      expect(
          f.service.state.bots.values
              .every((b) => f.service.state.accounts.containsKey(b.ownerId)),
          isTrue);
      expect(() => f.service.actor('draft0'), throwsA(error('forbidden')));
      expect(() => f.service.actor('missing'), throwsA(error('not_found')));
    });
    test('草案由自己 owner 入驻、退驻移除空间并释放额度，可复活相同编号', () {
      final f = Fixture(config: CommunityConfig(maxBotsPerOwner: 1));
      final draft = f.service
          .createBotDraft(actor: f.alice, id: 'draft', displayName: '草案');
      expect(() => f.service.admitBot(actor: f.bob, botId: draft.id),
          throwsA(error('forbidden')));
      f.service.admitBot(actor: f.alice, botId: draft.id);
      final actor = f.service.actor(draft.id);
      final space = f.space();
      f.join(f.alice, botId: draft.id);
      final msg = f.service.sendMessage(
          actor: actor, conversationId: space.defaultRoomId, parts: text('历史'));
      f.service.retireBot(actor: f.alice, botId: draft.id);
      expect(
          f.service.members(actor: f.alice, spaceId: space.id).map((p) => p.id),
          isNot(contains(draft.id)));
      expect(() => f.service.publishFeed(actor: actor, parts: text('失效')),
          throwsA(error('forbidden')));
      expect(f.service.message(actor: f.alice, messageId: msg.id).senderId,
          draft.id);
      f.bot(f.alice, 'replacement');
      expect(() => f.service.admitBot(actor: f.alice, botId: draft.id),
          throwsA(error('quota_exceeded')));
      f.service.retireBot(actor: f.alice, botId: 'replacement');
      expect(f.service.admitBot(actor: f.alice, botId: draft.id).id, draft.id);
    });
    test('所有 bot caps 仍不能授予社交和管理权限', () {
      final f = Fixture();
      final bot = f.bot(f.alice, 'bot');
      f.space();
      f.join(f.alice, botId: bot.id);
      final actions = <void Function()>[
        () =>
            f.service.registerBot(actor: bot, id: 'illegal', displayName: 'x'),
        () => f.service.createSpace(
            actor: bot, id: 'illegal', title: 'x', publicChannel: true),
        () => f.service.addFriend(actor: bot, targetId: 'bob'),
        () => f.service.removeFriend(actor: bot, targetId: 'bob'),
        () => f.service.joinSpace(actor: bot, spaceId: 'space'),
        () => f.service.leaveSpace(actor: bot, spaceId: 'space'),
        () => f.service
            .inviteToSpace(actor: bot, spaceId: 'space', principalId: 'bob'),
        () => f.service.kick(actor: bot, spaceId: 'space', principalId: 'bob'),
        () => f.service.setSpaceAdmin(
            actor: bot, spaceId: 'space', accountId: 'bob', enabled: true),
      ];
      for (final action in actions) {
        expect(action, throwsA(error('forbidden')));
      }
      expect(
          () => f.service
              .setBotCaps(actor: f.alice, botId: bot.id, caps: {'space.join'}),
          throwsA(error('bad_request')));
      expect(
          () => f.service
              .joinSpace(actor: f.bob, spaceId: 'space', botId: bot.id),
          throwsA(error('forbidden')));
    });
    test('内容 caps 分别限制发言/读取/发帖/回复/like', () {
      final f = Fixture();
      final bot = f.bot(f.alice, 'bot');
      final space = f.space();
      f.join(f.alice, botId: bot.id);
      final feed = f.service.publishFeed(
          actor: f.alice, parts: text('public'), visibility: 'public');
      f.service.setBotCaps(actor: f.alice, botId: bot.id, caps: {});
      expect(
          () => f.service.sendMessage(
              actor: bot,
              conversationId: space.defaultRoomId,
              parts: text('x')),
          throwsA(error('forbidden')));
      expect(
          () => f.service
              .messages(actor: bot, conversationId: space.defaultRoomId),
          throwsA(error('forbidden')));
      expect(() => f.service.publishFeed(actor: bot, parts: text('x')),
          throwsA(error('forbidden')));
      expect(
          () => f.service
              .commentFeed(actor: bot, postId: feed.id, parts: text('x')),
          throwsA(error('forbidden')));
      expect(() => f.service.likeFeed(actor: bot, postId: feed.id),
          throwsA(error('forbidden')));
      expect(f.service.conversations(actor: bot), isEmpty);
    });
    test('社区 owner 才能设置全局配置且 0 不限', () {
      final f = Fixture();
      expect(
          () => f.service.configureCommunity(
              actor: f.bob, config: CommunityConfig(maxBotsPerOwner: 0)),
          throwsA(error('forbidden')));
      f.service.configureCommunity(
          actor: f.alice,
          config: CommunityConfig(maxBotsPerOwner: 0, maxBots: 0));
      for (var i = 0; i < 12; i++) {
        f.bot(f.alice, 'bot$i');
      }
      expect(f.service.state.bots.length, 12);
      expect(() => CommunityConfig(maxBots: -1), throwsA(error('bad_request')));
    });
    test('社区总 bot 配额/账户配额/空间与每 owner 空间配额', () {
      final f = Fixture(
          config: CommunityConfig(
              maxAccounts: 3, maxBots: 1, maxSpaces: 2, maxSpacesPerOwner: 1));
      expect(
          () => f.service
              .registerAccount(id: 'fourth', name: 'fourth', displayName: 'x'),
          throwsA(error('quota_exceeded')));
      f.bot(f.alice, 'bot');
      expect(() => f.bot(f.bob, 'another'), throwsA(error('quota_exceeded')));
      f.space();
      expect(
          () => f.service.createSpace(
              actor: f.alice, id: 'second', title: 'x', publicChannel: true),
          throwsA(error('quota_exceeded')));
      f.service.createSpace(
          actor: f.bob, id: 'second', title: 'x', publicChannel: true);
      expect(
          () => f.service.createSpace(
              actor: f.carol, id: 'third', title: 'x', publicChannel: true),
          throwsA(error('quota_exceeded')));
    });
    test('固定 community owner 引导账户必须匹配', () {
      final s = ChatService(ChatState(communityOwnerId: 'admin'));
      expect(
          () => s.registerAccount(
              id: 'stranger', name: 'stranger', displayName: 'x'),
          throwsA(error('forbidden')));
      s.registerAccount(id: 'admin', name: 'Admin', displayName: '管理员');
      expect(s.state.accounts['admin']!.name, 'admin');
    });
  });

  group('空间、成员与房间管理', () {
    test('私域申请须管理员审批，invited=true 不能自行冒充邀请', () {
      final f = Fixture();
      final space = f.space(public: false);
      expect(f.service.discoverSpaces(actor: f.bob), isEmpty);
      expect(
          () => f.service
              .joinSpace(actor: f.bob, spaceId: space.id, invited: true),
          throwsA(error('forbidden')));
      final pending = f.service.joinSpace(actor: f.bob, spaceId: space.id);
      expect(pending.status, 'pending');
      expect(
          () => f.service
              .messages(actor: f.bob, conversationId: space.defaultRoomId),
          throwsA(error('forbidden')));
      expect(
          () => f.service.decideJoin(
              actor: f.carol,
              spaceId: space.id,
              principalId: 'bob',
              approve: true),
          throwsA(error('forbidden')));
      expect(
          f.service
              .joinRequests(actor: f.alice, spaceId: space.id)
              .single
              .principalId,
          'bob');
      f.service.decideJoin(
          actor: f.alice, spaceId: space.id, principalId: 'bob', approve: true);
      expect(
          f.service.messages(actor: f.bob, conversationId: space.defaultRoomId),
          isEmpty);
      expect(
          () => f.service.decideJoin(
              actor: f.alice,
              spaceId: space.id,
              principalId: 'bob',
              approve: true),
          throwsA(error('not_found')));
    });
    test('私域真实邀请由 owner 接受，拒绝申请后仍不可读', () {
      final f = Fixture();
      final bot = f.bot(f.bob, 'bot');
      f.space(public: false);
      f.service
          .inviteToSpace(actor: f.alice, spaceId: 'space', principalId: bot.id);
      expect(
          f.service
              .joinSpace(
                  actor: f.bob, spaceId: 'space', botId: bot.id, invited: true)
              .status,
          'joined');
      f.join(f.carol);
      f.service.decideJoin(
          actor: f.alice,
          spaceId: 'space',
          principalId: 'carol',
          approve: false);
      expect(() => f.service.members(actor: f.carol, spaceId: 'space'),
          throwsA(error('forbidden')));
    });
    test('频道发现只元数据；自助加入不许任何管理员审批', () {
      final f = Fixture();
      final space = f.space();
      expect(f.service.discoverSpaces(actor: f.bob).single.id, space.id);
      expect(() => f.service.rooms(actor: f.bob, spaceId: space.id),
          throwsA(error('forbidden')));
      expect(() => f.service.members(actor: f.bob, spaceId: space.id),
          throwsA(error('forbidden')));
      expect(f.service.joinSpace(actor: f.bob, spaceId: space.id).status,
          'joined');
      expect(
          () => f.service.decideJoin(
              actor: f.alice,
              spaceId: space.id,
              principalId: 'bob',
              approve: true),
          throwsA(error('forbidden')));
      expect(() => f.service.joinRequests(actor: f.alice, spaceId: space.id),
          throwsA(error('forbidden')));
    });
    test('每个聊天室唯一茶会，论坛没有影子，新房间受数量限制', () {
      final f = Fixture();
      final space = f.space(config: SpaceConfig(maxRooms: 3));
      final extra = f.service.createRoom(
          actor: f.alice, spaceId: space.id, id: 'extra', title: '第二间');
      final forum = f.service.createRoom(
          actor: f.alice,
          spaceId: space.id,
          id: 'forum',
          title: '论坛',
          kind: 'forum');
      expect(extra.shadowConversationId, isNotNull);
      expect(forum.shadowConversationId, isNull);
      expect(
          f.service.state.conversations.values
              .where((c) => c.kind == 'shadow')
              .length,
          2);
      expect(
          () => f.service.createRoom(
              actor: f.alice, spaceId: space.id, id: 'too-many', title: 'x'),
          throwsA(error('quota_exceeded')));
      expect(
          () => f.service.createRoom(
              actor: f.alice,
              spaceId: space.id,
              id: extra.id,
              title: 'duplicate'),
          throwsA(error('conflict')));
    });
    test('空间成员、bot总额和每 owner bot 配额相互独立', () {
      final f = Fixture();
      final a1 = f.bot(f.alice, 'a1');
      final a2 = f.bot(f.alice, 'a2');
      final b1 = f.bot(f.bob, 'b1');
      final c1 = f.bot(f.carol, 'c1');
      f.space(
          config: SpaceConfig(maxMembers: 4, maxBots: 2, maxBotsPerOwner: 1));
      f.join(f.alice, botId: a1.id);
      expect(() => f.join(f.alice, botId: a2.id),
          throwsA(error('quota_exceeded')));
      f.join(f.bob, botId: b1.id);
      expect(() => f.join(f.carol, botId: c1.id),
          throwsA(error('quota_exceeded')));
      f.join(f.bob);
      expect(() => f.join(f.carol), throwsA(error('quota_exceeded')));
    });
    test('空间所有配额 0 不限，allowBots=false 是独立禁止', () {
      final f = Fixture(config: CommunityConfig(maxBotsPerOwner: 0));
      f.space(
          config: SpaceConfig(
              maxBots: 0, maxBotsPerOwner: 0, maxMembers: 0, maxRooms: 0));
      for (var i = 0; i < 12; i++) {
        final b = f.bot(f.alice, 'b$i');
        f.join(f.alice, botId: b.id);
      }
      expect(f.service.members(actor: f.alice, spaceId: 'space').length, 13);
      f.service.configureSpace(
          actor: f.alice,
          spaceId: 'space',
          config: SpaceConfig(allowBots: false));
      final other = f.bot(f.bob, 'other');
      expect(() => f.join(f.bob, botId: other.id), throwsA(error('forbidden')));
    });
    test('审批时重新核对配额，失败保持 pending 且无部分写入', () {
      final f = Fixture();
      f.space(public: false, config: SpaceConfig(maxMembers: 2));
      f.join(f.bob);
      f.join(f.carol);
      f.service.decideJoin(
          actor: f.alice, spaceId: 'space', principalId: 'bob', approve: true);
      final count = f.service.state.events.length;
      expect(
          () => f.service.decideJoin(
              actor: f.alice,
              spaceId: 'space',
              principalId: 'carol',
              approve: true),
          throwsA(error('quota_exceeded')));
      expect(f.service.state.events.length, count);
      expect(
          f.service
              .joinRequests(actor: f.alice, spaceId: 'space')
              .single
              .principalId,
          'carol');
    });
    test('退出保留已获区间历史，未来消息和成员房间列表拒绝', () {
      final f = Fixture();
      final space = f.space();
      f.join(f.bob);
      final msg = f.service.sendMessage(
          actor: f.bob, conversationId: space.defaultRoomId, parts: text('x'));
      f.service.leaveSpace(actor: f.bob, spaceId: space.id);
      expect(f.service.conversations(actor: f.bob).map((c) => c.id),
          contains(space.defaultRoomId));
      expect(
          f.service
              .messages(actor: f.bob, conversationId: space.defaultRoomId)
              .single
              .id,
          msg.id);
      expect(f.service.message(actor: f.bob, messageId: msg.id).id, msg.id);
      final future = f.service.sendMessage(
          actor: f.alice,
          conversationId: space.defaultRoomId,
          parts: text('future'));
      expect(
          f.service
              .messages(actor: f.bob, conversationId: space.defaultRoomId)
              .map((m) => m.id),
          [msg.id]);
      expect(() => f.service.message(actor: f.bob, messageId: future.id),
          throwsA(error('forbidden')));
      expect(
          () => f.service.sendMessage(
              actor: f.bob,
              conversationId: space.defaultRoomId,
              parts: text('new')),
          throwsA(error('forbidden')));
      expect(() => f.service.rooms(actor: f.bob, spaceId: space.id),
          throwsA(error('forbidden')));
      expect(() => f.service.members(actor: f.bob, spaceId: space.id),
          throwsA(error('forbidden')));
      expect(() => f.service.leaveSpace(actor: f.alice, spaceId: space.id),
          throwsA(error('forbidden')));
    });
    test('管理员只能 owner 设置，kick 不等于 ban，ban owner 同时阻断其 bot', () {
      final f = Fixture();
      final b = f.bot(f.bob, 'b');
      final space = f.space();
      f.join(f.bob);
      f.join(f.carol);
      f.join(f.bob, botId: b.id);
      f.service.setSpaceAdmin(
          actor: f.alice, spaceId: space.id, accountId: 'bob', enabled: true);
      expect(
          () => f.service.setSpaceAdmin(
              actor: f.bob,
              spaceId: space.id,
              accountId: 'carol',
              enabled: true),
          throwsA(error('forbidden')));
      expect(
          () => f.service
              .kick(actor: f.bob, spaceId: space.id, principalId: 'alice'),
          throwsA(error('forbidden')));
      f.service.kick(actor: f.bob, spaceId: space.id, principalId: 'carol');
      expect(f.service.joinSpace(actor: f.carol, spaceId: space.id).status,
          'joined');
      f.service.ban(
          actor: f.alice, spaceId: space.id, principalId: 'bob', banned: true);
      expect(() => f.service.joinSpace(actor: f.bob, spaceId: space.id),
          throwsA(error('forbidden')));
      expect(
          () =>
              f.service.joinSpace(actor: f.bob, spaceId: space.id, botId: b.id),
          throwsA(error('forbidden')));
      expect(f.service.messages(actor: b, conversationId: space.defaultRoomId),
          isEmpty);
      f.service.ban(
          actor: f.alice, spaceId: space.id, principalId: 'bob', banned: false);
      f.join(f.bob);
      expect(
          () => f.service
              .kick(actor: f.bob, spaceId: space.id, principalId: 'carol'),
          throwsA(error('forbidden')));
    });
    test('房间 allowlist 进一步限制，房间 ban 不影响其他房间，读写都校验', () {
      final f = Fixture();
      final space = f.space();
      f.join(f.bob);
      final privateRoom = f.service.createRoom(
          actor: f.alice,
          spaceId: space.id,
          id: 'private',
          title: 'private',
          config: RoomConfig(allowedPrincipalIds: {'alice'}));
      expect(f.service.rooms(actor: f.bob, spaceId: space.id).map((r) => r.id),
          isNot(contains(privateRoom.id)));
      expect(
          () =>
              f.service.messages(actor: f.bob, conversationId: privateRoom.id),
          throwsA(error('forbidden')));
      f.service.configureRoom(
          actor: f.alice, roomId: privateRoom.id, config: RoomConfig());
      f.service.ban(
          actor: f.alice,
          spaceId: space.id,
          roomId: privateRoom.id,
          principalId: 'bob',
          banned: true);
      expect(f.service.messages(actor: f.bob, conversationId: privateRoom.id),
          isEmpty);
      expect(
          f.service
              .sendMessage(
                  actor: f.bob,
                  conversationId: space.defaultRoomId,
                  parts: text('ok'))
              .senderId,
          'bob');
    });
    test('mute 时限与解除，readOnly 和机器人发言开关', () {
      final f = Fixture();
      final b = f.bot(f.bob, 'b');
      final space = f.space();
      f.join(f.bob);
      f.join(f.bob, botId: b.id);
      f.service.mute(
          actor: f.alice,
          spaceId: space.id,
          principalId: 'bob',
          untilMs: f.time.millisecondsSinceEpoch + 1000);
      expect(
          () => f.service.sendMessage(
              actor: b,
              conversationId: space.defaultRoomId,
              parts: text('muted')),
          throwsA(error('forbidden')));
      expect(f.service.messages(actor: b, conversationId: space.defaultRoomId),
          isEmpty);
      f.advance(const Duration(seconds: 1));
      f.service.sendMessage(
          actor: b,
          conversationId: space.defaultRoomId,
          parts: text('unmuted'));
      f.service.mute(
          actor: f.alice,
          spaceId: space.id,
          roomId: space.defaultRoomId,
          principalId: 'bob');
      expect(
          () => f.service.sendMessage(
              actor: f.bob,
              conversationId: space.defaultRoomId,
              parts: text('x')),
          throwsA(error('forbidden')));
      f.service.mute(
          actor: f.alice,
          spaceId: space.id,
          roomId: space.defaultRoomId,
          principalId: 'bob',
          muted: false);
      f.service.configureRoom(
          actor: f.alice,
          roomId: space.defaultRoomId,
          config: RoomConfig(allowBotMessages: false));
      f.service.sendMessage(
          actor: f.bob,
          conversationId: space.defaultRoomId,
          parts: text('human'));
      expect(
          () => f.service.sendMessage(
              actor: b,
              conversationId: space.defaultRoomId,
              parts: text('bot')),
          throwsA(error('forbidden')));
      f.service.configureRoom(
          actor: f.alice,
          roomId: space.defaultRoomId,
          config: RoomConfig(readOnly: true));
      expect(
          () => f.service.sendMessage(
              actor: f.bob,
              conversationId: space.defaultRoomId,
              parts: text('x')),
          throwsA(error('forbidden')));
    });
  });

  group('茶会、闺房、关系和双 owner 续期', () {
    test('茶会 bot 能写，合资格人只读，非成员不能读', () {
      final f = Fixture();
      final bot = f.bot(f.alice, 'bot');
      final space = f.space();
      f.join(f.alice, botId: bot.id);
      final shadow =
          f.service.state.rooms[space.defaultRoomId]!.shadowConversationId!;
      final msg = f.service
          .sendMessage(actor: bot, conversationId: shadow, parts: text('茶会'));
      expect(
          f.service.messages(actor: f.alice, conversationId: shadow).single.id,
          msg.id);
      expect(
          () => f.service.sendMessage(
              actor: f.alice, conversationId: shadow, parts: text('越界')),
          throwsA(error('forbidden')));
      expect(() => f.service.messages(actor: f.bob, conversationId: shadow),
          throwsA(error('forbidden')));
      expect(f.service.state.conversations[shadow]!.participantIds, isEmpty);
    });
    test('同一对只一个 DM；双方 owner 可读全部，不能写，无已读/在线事件', () {
      final f = Fixture();
      final (a, b, c) = f.botDm();
      expect(f.service.directConversation(actor: b, targetId: a.id).id, c.id);
      for (var i = 0; i < 3; i++) {
        f.service.sendMessage(
            actor: i.isEven ? a : b, conversationId: c.id, parts: text('$i'));
      }
      final events = f.service.state.events.length;
      for (final owner in [f.alice, f.bob]) {
        expect(
            f.service.messages(actor: owner, conversationId: c.id).length, 3);
        expect(f.service.conversations(actor: owner).map((c) => c.id),
            contains(c.id));
        expect(
            () => f.service.sendMessage(
                actor: owner, conversationId: c.id, parts: text('干涉')),
            throwsA(error('forbidden')));
      }
      expect(f.service.state.events.length, events);
      expect(c.participantIds, [a.id, b.id]);
      expect(() => f.service.messages(actor: f.carol, conversationId: c.id),
          throwsA(error('forbidden')));
      expect(
          f.service.state.events
              .any((e) => e.type.contains('read') || e.type.contains('online')),
          isFalse);
    });
    test('owner 好友不足以准许 bot-bot；无共同空间需双方许可', () {
      final f = Fixture();
      final a = f.bot(f.alice, 'a');
      final b = f.bot(f.bob, 'b');
      f.service.addFriend(actor: f.alice, targetId: f.bob.id);
      expect(() => f.service.directConversation(actor: a, targetId: b.id),
          throwsA(error('forbidden')));
      f.service.permitBotDirect(actor: f.alice, botId: a.id, targetBotId: b.id);
      expect(() => f.service.directConversation(actor: a, targetId: b.id),
          throwsA(error('forbidden')));
      expect(
          () => f.service
              .permitBotDirect(actor: f.alice, botId: b.id, targetBotId: a.id),
          throwsA(error('forbidden')));
      f.service.permitBotDirect(actor: f.bob, botId: b.id, targetBotId: a.id);
      expect(f.service.directConversation(actor: a, targetId: b.id).kind,
          'direct');
    });
    test('共同空间丢失冻结写；历史永久可读；单方续期不恢复，双方才恢复', () {
      final f = Fixture();
      final (a, b, c) = f.botDm();
      final old = f.service
          .sendMessage(actor: a, conversationId: c.id, parts: text('历史'));
      f.service.leaveSpace(actor: f.bob, spaceId: 'space', botId: b.id);
      expect(
          () => f.service
              .sendMessage(actor: a, conversationId: c.id, parts: text('冻结')),
          throwsA(error('forbidden')));
      expect(
          f.service.messages(actor: b, conversationId: c.id).single.id, old.id);
      expect(f.service.messages(actor: f.bob, conversationId: c.id).single.id,
          old.id);
      f.service.renewDirect(actor: f.alice, conversationId: c.id);
      expect(
          () => f.service
              .sendMessage(actor: b, conversationId: c.id, parts: text('单方')),
          throwsA(error('forbidden')));
      expect(() => f.service.renewDirect(actor: f.carol, conversationId: c.id),
          throwsA(error('forbidden')));
      f.service.renewDirect(actor: f.bob, conversationId: c.id);
      expect(
          f.service
              .sendMessage(actor: b, conversationId: c.id, parts: text('双方'))
              .senderId,
          b.id);
    });
    test('显式许可到期/撤销即时冻结写，历史不丢', () {
      final f = Fixture();
      final a = f.bot(f.alice, 'a');
      final b = f.bot(f.bob, 'b');
      final expires = f.time.millisecondsSinceEpoch + 1000;
      f.service.permitBotDirect(
          actor: f.alice, botId: a.id, targetBotId: b.id, untilMs: expires);
      f.service.permitBotDirect(actor: f.bob, botId: b.id, targetBotId: a.id);
      final c = f.service.directConversation(actor: a, targetId: b.id);
      f.service
          .sendMessage(actor: a, conversationId: c.id, parts: text('before'));
      f.advance(const Duration(seconds: 1));
      expect(
          () => f.service.sendMessage(
              actor: b, conversationId: c.id, parts: text('expired')),
          throwsA(error('forbidden')));
      expect(
          f.service.messages(actor: f.alice, conversationId: c.id).length, 1);
      f.service.permitBotDirect(actor: f.alice, botId: a.id, targetBotId: b.id);
      f.service.permitBotDirect(
          actor: f.bob, botId: b.id, targetBotId: a.id, allow: false);
      expect(
          () => f.service.sendMessage(
              actor: a, conversationId: c.id, parts: text('revoked')),
          throwsA(error('forbidden')));
    });
    test('最大次数可配置、双 owner 重置轮次且旧票不能复用', () {
      final f = Fixture(config: CommunityConfig(maxDirectMessages: 1));
      final (a, b, c) = f.botDm();
      f.service.sendMessage(actor: a, conversationId: c.id, parts: text('one'));
      expect(
          () => f.service
              .sendMessage(actor: b, conversationId: c.id, parts: text('two')),
          throwsA(error('rate_limited')));
      f.service.renewDirect(actor: f.alice, conversationId: c.id);
      expect(
          () => f.service.sendMessage(
              actor: b, conversationId: c.id, parts: text('one vote')),
          throwsA(error('rate_limited')));
      f.service.renewDirect(actor: f.bob, conversationId: c.id);
      f.service.sendMessage(
          actor: b, conversationId: c.id, parts: text('new round'));
      f.service.renewDirect(actor: f.alice, conversationId: c.id);
      expect(
          () => f.service.sendMessage(
              actor: a, conversationId: c.id, parts: text('stale vote')),
          throwsA(error('rate_limited')));
      f.service.renewDirect(actor: f.bob, conversationId: c.id);
      expect(
          f.service
              .sendMessage(actor: a, conversationId: c.id, parts: text('next'))
              .senderId,
          a.id);
    });
    test('同 owner 的两个 bot 续期只需该唯一 owner，不允许第三方', () {
      final f = Fixture(config: CommunityConfig(maxDirectMessages: 1));
      final a = f.bot(f.alice, 'a');
      final b = f.bot(f.alice, 'b');
      f.service.permitBotDirect(actor: f.alice, botId: a.id, targetBotId: b.id);
      final c = f.service.directConversation(actor: a, targetId: b.id);
      f.service.sendMessage(actor: a, conversationId: c.id, parts: text('x'));
      f.service.renewDirect(actor: f.alice, conversationId: c.id);
      expect(
          f.service
              .sendMessage(actor: b, conversationId: c.id, parts: text('y'))
              .senderId,
          b.id);
    });
    test('bot DM 每小时新建计数双方均约束，重复查询不消耗额度', () {
      final f = Fixture(config: CommunityConfig(botDirectsPerHour: 1));
      final a = f.bot(f.alice, 'a');
      final b = f.bot(f.bob, 'b');
      final c = f.bot(f.carol, 'c');
      f.space();
      f.join(f.alice, botId: a.id);
      f.join(f.bob, botId: b.id);
      f.join(f.carol, botId: c.id);
      final dm = f.service.directConversation(actor: a, targetId: b.id);
      expect(f.service.directConversation(actor: b, targetId: a.id).id, dm.id);
      expect(() => f.service.directConversation(actor: c, targetId: b.id),
          throwsA(error('rate_limited')));
      f.advance(const Duration(hours: 1));
      expect(f.service.directConversation(actor: c, targetId: b.id).id,
          isNot(dm.id));
    });
    test('普通人和 bot 对人 DM 遵循好友关系，删好友停止新写但历史保留', () {
      final f = Fixture();
      final bot = f.bot(f.alice, 'bot');
      expect(
          () =>
              f.service.directConversation(actor: f.alice, targetId: f.bob.id),
          throwsA(error('forbidden')));
      f.service.addFriend(actor: f.alice, targetId: f.bob.id);
      final dm =
          f.service.directConversation(actor: f.alice, targetId: f.bob.id);
      f.service.sendMessage(
          actor: f.alice, conversationId: dm.id, parts: text('hello'));
      expect(f.service.directConversation(actor: bot, targetId: f.bob.id).kind,
          'direct');
      f.service.removeFriend(actor: f.alice, targetId: f.bob.id);
      expect(
          () => f.service.sendMessage(
              actor: f.bob, conversationId: dm.id, parts: text('no')),
          throwsA(error('forbidden')));
      expect(
          f.service
              .messages(actor: f.bob, conversationId: dm.id)
              .single
              .senderId,
          'alice');
    });
    test('空间 allowBotDirects 配置阻断共同空间可达性', () {
      final f = Fixture();
      final a = f.bot(f.alice, 'a');
      final b = f.bot(f.bob, 'b');
      f.space(config: SpaceConfig(allowBotDirects: false));
      f.join(f.alice, botId: a.id);
      f.join(f.bob, botId: b.id);
      expect(() => f.service.directConversation(actor: a, targetId: b.id),
          throwsA(error('forbidden')));
    });
  });

  group('消息、幂等、限流和不可变值', () {
    test('能力撤销后成功请求仍可幂等确认，非法新payload同key仍冲突', () {
      final f = Fixture();
      final bot = f.bot(f.alice, 'bot');
      final original = f.service.publishFeed(
          actor: bot, parts: text('original'), idempotencyKey: 'feed-key');
      f.service.setBotCaps(actor: f.alice, botId: bot.id, caps: {});
      final count = f.service.state.events.length;
      expect(
          f.service
              .publishFeed(
                  actor: bot,
                  parts: text('original'),
                  idempotencyKey: 'feed-key')
              .id,
          original.id);
      expect(
          () => f.service.publishFeed(
              actor: bot,
              parts: [],
              visibility: 'invalid',
              idempotencyKey: 'feed-key'),
          throwsA(error('idempotency_conflict')));
      expect(f.service.state.events.length, count);
    });
    test('消息保留 sender 身份、时间注入和 JSON 消息段深不可变', () {
      final f = Fixture();
      final b = f.bot(f.alice, 'b');
      final space = f.space();
      f.join(f.alice, botId: b.id);
      final input = text('before');
      final msg = f.service.sendMessage(
          actor: b, conversationId: space.defaultRoomId, parts: input);
      (input[0]['data'] as JsonMap)['text'] = 'after';
      input.clear();
      expect((msg.parts.single['data'] as Map)['text'], 'before');
      expect(msg.createdAtMs, f.time.millisecondsSinceEpoch);
      expect(msg.senderId, b.id);
      expect(() => msg.parts.add({'type': 'text'}), throwsUnsupportedError);
      expect(() => (msg.parts[0]['data'] as Map)['text'] = 'mutate',
          throwsUnsupportedError);
      expect(() => f.service.state.messages.clear(), throwsUnsupportedError);
      expect(() => f.service.state.events.first.data.clear(),
          throwsUnsupportedError);
    });
    test('相同幂等请求跨 JSON key 顺序返回稳定且只提交一次，异 payload 冲突', () {
      final f = Fixture();
      final space = f.space();
      final original = f.service.sendMessage(
          actor: f.alice,
          conversationId: space.defaultRoomId,
          parts: text('a'),
          idempotencyKey: 'k');
      final count = f.service.state.events.length;
      f.advance(const Duration(days: 1));
      final retry = f.service.sendMessage(
          actor: f.alice,
          conversationId: space.defaultRoomId,
          parts: [
            {
              'data': {'text': 'a'},
              'type': 'text'
            }
          ],
          idempotencyKey: 'k');
      expect(retry.toJson(), original.toJson());
      expect(f.service.state.events.length, count);
      expect(
          () => f.service.sendMessage(
              actor: f.alice,
              conversationId: space.defaultRoomId,
              parts: text('b'),
              idempotencyKey: 'k'),
          throwsA(error('idempotency_conflict')));
      expect(
          () => f.service.publishFeed(
              actor: f.alice, parts: text('a'), idempotencyKey: 'k'),
          throwsA(error('idempotency_conflict')));
      f.join(f.bob);
      expect(
          f.service
              .sendMessage(
                  actor: f.bob,
                  conversationId: space.defaultRoomId,
                  parts: text('a'),
                  idempotencyKey: 'k')
              .id,
          isNot(original.id));
    });
    test('重试不会再次耗限额，当前禁言后原请求仍稳定返回，读取另行鉴权', () {
      final f = Fixture(config: CommunityConfig(botMessagesPerHour: 1));
      final bot = f.bot(f.bob, 'bot');
      final space = f.space();
      f.join(f.bob, botId: bot.id);
      final sent = f.service.sendMessage(
          actor: bot,
          conversationId: space.defaultRoomId,
          parts: text('x'),
          idempotencyKey: 'once');
      f.service.mute(actor: f.alice, spaceId: space.id, principalId: bot.id);
      expect(
          f.service
              .sendMessage(
                  actor: bot,
                  conversationId: space.defaultRoomId,
                  parts: text('x'),
                  idempotencyKey: 'once')
              .id,
          sent.id);
      f.service.kick(actor: f.alice, spaceId: space.id, principalId: bot.id);
      expect(
          f.service
              .messages(actor: bot, conversationId: space.defaultRoomId)
              .single
              .id,
          sent.id);
    });
    test('每小时边界精确，0 不限，慢速模式也对人有效', () {
      final f = Fixture(config: CommunityConfig(botMessagesPerHour: 1));
      final bot = f.bot(f.alice, 'bot');
      final space = f.space();
      f.join(f.alice, botId: bot.id);
      f.service.sendMessage(
          actor: bot, conversationId: space.defaultRoomId, parts: text('one'));
      expect(
          () => f.service.sendMessage(
              actor: bot,
              conversationId: space.defaultRoomId,
              parts: text('two')),
          throwsA(error('rate_limited')));
      f.advance(const Duration(hours: 1));
      f.service.sendMessage(
          actor: bot,
          conversationId: space.defaultRoomId,
          parts: text('new hour'));
      f.service.configureCommunity(
          actor: f.alice,
          config: CommunityConfig(botMessagesPerHour: 0, maxDirectMessages: 0));
      for (var i = 0; i < 5; i++) {
        f.service.sendMessage(
            actor: bot, conversationId: space.defaultRoomId, parts: text('$i'));
      }
      f.service.configureSpace(
          actor: f.alice,
          spaceId: space.id,
          config: SpaceConfig(slowModeMs: 1000));
      f.service.sendMessage(
          actor: f.alice,
          conversationId: space.defaultRoomId,
          parts: text('human'));
      expect(
          () => f.service.sendMessage(
              actor: f.alice,
              conversationId: space.defaultRoomId,
              parts: text('fast')),
          throwsA(error('rate_limited')));
      f.advance(const Duration(seconds: 1));
      f.service.sendMessage(
          actor: f.alice,
          conversationId: space.defaultRoomId,
          parts: text('later'));
    });
    test('房间每小时限额共享主聊天室和shadow，不能绕过', () {
      final f = Fixture();
      final bot = f.bot(f.alice, 'b');
      final space = f.space();
      f.join(f.alice, botId: bot.id);
      f.service.configureRoom(
          actor: f.alice,
          roomId: space.defaultRoomId,
          config: RoomConfig(messagesPerHour: 1));
      f.service.sendMessage(
          actor: bot, conversationId: space.defaultRoomId, parts: text('main'));
      expect(
          () => f.service.sendMessage(
              actor: bot,
              conversationId: '${space.defaultRoomId}#shadow',
              parts: text('shadow')),
          throwsA(error('rate_limited')));
    });
    test('分页按提交顺序，游标须属于同一会话，非法 limit 拒绝', () {
      final f = Fixture();
      final space = f.space();
      final ids = <String>[];
      for (var i = 0; i < 4; i++) {
        ids.add(f.service
            .sendMessage(
                actor: f.alice,
                conversationId: space.defaultRoomId,
                parts: text('$i'))
            .id);
      }
      expect(
          f.service
              .messages(
                  actor: f.alice, conversationId: space.defaultRoomId, limit: 2)
              .map((m) => m.id),
          ids.skip(2));
      expect(
          f.service
              .messages(
                  actor: f.alice,
                  conversationId: space.defaultRoomId,
                  limit: 2,
                  beforeId: ids[2])
              .map((m) => m.id),
          ids.take(2));
      expect(
          () => f.service.messages(
              actor: f.alice, conversationId: space.defaultRoomId, limit: 0),
          throwsA(error('bad_request')));
      expect(
          () => f.service.messages(
              actor: f.alice,
              conversationId: space.defaultRoomId,
              beforeId: 'wrong'),
          throwsA(error('not_found')));
    });
    test('无效输入失败无部分事件或计数', () {
      final f = Fixture();
      final space = f.space();
      final before = jsonEncode(f.service.state.toJson());
      for (final parts in <List<JsonMap>>[
        [],
        [
          {'data': {}}
        ],
        [
          {'type': 'text', 'bad': double.nan}
        ],
        [
          {'type': 'text', 'bad': Object()}
        ]
      ]) {
        expect(
            () => f.service.sendMessage(
                actor: f.alice,
                conversationId: space.defaultRoomId,
                parts: parts),
            throwsA(error('bad_request')));
      }
      expect(jsonEncode(f.service.state.toJson()), before);
      expect(
          () => f.service.sendMessage(
              actor: f.alice,
              conversationId: space.defaultRoomId,
              parts: text('x'),
              idempotencyKey: ''),
          throwsA(error('bad_request')));
    });
    test('广播覆盖普通/论坛消息入口，幂等不重复广播，查询没有副作用', () async {
      final f = Fixture();
      final space = f.space();
      final seen = <MessageRecord>[];
      final subscription = f.service.messageEvents.listen(seen.add);
      final first = f.service.sendMessage(
          actor: f.alice,
          conversationId: space.defaultRoomId,
          parts: text('x'),
          idempotencyKey: 'k');
      f.service.sendMessage(
          actor: f.alice,
          conversationId: space.defaultRoomId,
          parts: text('x'),
          idempotencyKey: 'k');
      final forum = f.service.createRoom(
          actor: f.alice,
          spaceId: space.id,
          id: 'forum',
          title: '论坛',
          kind: 'forum');
      final post = f.service.createForumPost(
          actor: f.alice,
          roomId: forum.id,
          title: 'title',
          parts: text('post'));
      final reply = f.service.replyForumPost(
          actor: f.alice, postId: post.id, parts: text('reply'));
      await Future<void>.delayed(Duration.zero);
      expect(seen.map((m) => m.id), [first.id, post.messageId, reply.id]);
      await subscription.cancel();
      await f.service.close();
      expect(() => f.service.friends(actor: f.alice),
          throwsA(error('bad_request')));
    });
    test('用户自定义会话编号不应覆盖自动生成 DM', () {
      final f = Fixture();
      f.service.addFriend(actor: f.alice, targetId: f.bob.id);
      final next = f.service.state.events.length + 2;
      f.service.createSpace(
          actor: f.alice,
          id: 'custom',
          title: 'x',
          publicChannel: true,
          defaultRoomId: 'dm:$next');
      final dm =
          f.service.directConversation(actor: f.alice, targetId: f.bob.id);
      expect(dm.id, isNot('dm:$next'));
      expect(f.service.state.conversations['dm:$next']!.kind, 'chat');
    });
  });

  group('论坛、朋友圈、可见性和隐藏', () {
    test('共同空间只授予空间内容和bot可达性，不泄露好友或private朋友圈', () {
      final f = Fixture();
      final a = f.bot(f.alice, 'a');
      final b = f.bot(f.bob, 'b');
      f.space();
      f.join(f.alice, botId: a.id);
      f.join(f.bob, botId: b.id);
      f.join(f.bob);
      final friends = f.service.publishFeed(actor: a, parts: text('friends'));
      final private = f.service
          .publishFeed(actor: a, parts: text('private'), visibility: 'private');
      f.service.directConversation(actor: a, targetId: b.id);
      for (final viewer in [b, f.bob, f.carol]) {
        expect(f.service.feed(actor: viewer), isEmpty);
        expect(() => f.service.feedPost(actor: viewer, postId: friends.id),
            throwsA(error('forbidden')));
        expect(() => f.service.feedPost(actor: viewer, postId: private.id),
            throwsA(error('forbidden')));
      }
    });
    test('每帖子独立会话，人 bot 平等发帖与回复，成员权限贯穿所有查询', () {
      final f = Fixture();
      final bot = f.bot(f.bob, 'bot');
      final space = f.space();
      f.join(f.bob, botId: bot.id);
      final room = f.service.createRoom(
          actor: f.alice,
          spaceId: space.id,
          id: 'forum',
          title: '论坛',
          kind: 'forum');
      final a = f.service.createForumPost(
          actor: f.alice, roomId: room.id, title: '人帖', parts: text('a'));
      final b = f.service.createForumPost(
          actor: bot, roomId: room.id, title: 'bot帖', parts: text('b'));
      expect(a.conversationId, isNot(b.conversationId));
      f.service.replyForumPost(actor: bot, postId: a.id, parts: text('bot回复'));
      f.service
          .replyForumPost(actor: f.alice, postId: b.id, parts: text('人回复'));
      expect(
          f.service
              .messages(actor: bot, conversationId: a.conversationId)
              .map((m) => m.senderId),
          ['alice', bot.id]);
      expect(f.service.forumPosts(actor: bot, roomId: room.id).length, 2);
      expect(() => f.service.forumPosts(actor: f.carol, roomId: room.id),
          throwsA(error('forbidden')));
      expect(
          () => f.service
              .replyForumPost(actor: f.carol, postId: a.id, parts: text('x')),
          throwsA(error('forbidden')));
      expect(
          () => f.service.sendMessage(
              actor: bot,
              conversationId: a.conversationId,
              parts: text('wrong')),
          throwsA(error('bad_request')));
    });
    test('forum和feed共用bot每小时发帖额度，回复有独立内容能力', () {
      final f = Fixture(config: CommunityConfig(botPostsPerHour: 1));
      final bot = f.bot(f.alice, 'bot');
      final space = f.space();
      f.join(f.alice, botId: bot.id);
      final room = f.service.createRoom(
          actor: f.alice,
          spaceId: space.id,
          id: 'forum',
          title: '论坛',
          kind: 'forum');
      final p = f.service.createForumPost(
          actor: bot, roomId: room.id, title: 'one', parts: text('post'));
      expect(() => f.service.publishFeed(actor: bot, parts: text('feed')),
          throwsA(error('rate_limited')));
      f.service.replyForumPost(actor: bot, postId: p.id, parts: text('reply'));
      f.advance(const Duration(hours: 1));
      expect(f.service.publishFeed(actor: bot, parts: text('feed')).authorId,
          bot.id);
    });
    test('朋友圈 public/friends/private 对人 bot 对称，删好友立刻过滤帖子评论like', () {
      final f = Fixture();
      final bot = f.bot(f.bob, 'bot');
      final pub = f.service
          .publishFeed(actor: bot, parts: text('public'), visibility: 'public');
      final friends = f.service.publishFeed(actor: bot, parts: text('friends'));
      final own = f.service.publishFeed(
          actor: bot, parts: text('private'), visibility: 'private');
      expect(f.service.feed(actor: f.alice).map((p) => p.id), [pub.id]);
      expect(f.service.feed(actor: bot).map((p) => p.id),
          [own.id, friends.id, pub.id]);
      expect(
          () => f.service.commentFeed(
              actor: f.alice, postId: friends.id, parts: text('invisible')),
          throwsA(error('forbidden')));
      expect(() => f.service.likeFeed(actor: f.alice, postId: friends.id),
          throwsA(error('forbidden')));
      f.service.addFriend(actor: f.alice, targetId: f.bob.id);
      final comment = f.service.commentFeed(
          actor: f.alice, postId: friends.id, parts: text('人评 bot'));
      f.service.likeFeed(actor: f.alice, postId: friends.id);
      expect(f.service.feedComments(actor: bot, postId: friends.id).single.id,
          comment.id);
      expect(f.service.feedLikes(actor: bot, postId: friends.id), {'alice'});
      expect(() => f.service.feedPost(actor: f.bob, postId: own.id),
          throwsA(error('forbidden')));
      final human = f.service.publishFeed(actor: f.alice, parts: text('人帖'));
      expect(
          f.service
              .commentFeed(actor: bot, postId: human.id, parts: text('bot评人'))
              .authorId,
          bot.id);
      f.service.removeFriend(actor: f.alice, targetId: f.bob.id);
      expect(f.service.feed(actor: f.alice).map((p) => p.id),
          isNot(contains(friends.id)));
      expect(() => f.service.feedComments(actor: f.alice, postId: friends.id),
          throwsA(error('forbidden')));
      expect(() => f.service.feedLikes(actor: f.alice, postId: friends.id),
          throwsA(error('forbidden')));
    });
    test('like是集合、unlike可切换，不可见分页游标不泄露', () {
      final f = Fixture();
      final p = f.service
          .publishFeed(actor: f.alice, parts: text('x'), visibility: 'public');
      f.service.likeFeed(actor: f.bob, postId: p.id);
      f.service.likeFeed(actor: f.bob, postId: p.id);
      expect(f.service.feedLikes(actor: f.alice, postId: p.id), {'bob'});
      f.service.likeFeed(actor: f.bob, postId: p.id, liked: false);
      expect(f.service.feedLikes(actor: f.alice, postId: p.id), isEmpty);
      final hidden = f.service.publishFeed(
          actor: f.alice, parts: text('only me'), visibility: 'private');
      expect(() => f.service.feed(actor: f.bob, beforeId: hidden.id),
          throwsA(error('not_found')));
    });
    test('内容管理隐藏但原事件不删、不提供撤回，帖子隐藏封锁线程读写', () {
      final f = Fixture();
      final space = f.space();
      f.join(f.bob);
      final msg = f.service.sendMessage(
          actor: f.bob,
          conversationId: space.defaultRoomId,
          parts: text('original'));
      final original = f.service.state.events.last.toJson();
      expect(
          () => f.service
              .hideContent(actor: f.bob, kind: 'message', contentId: msg.id),
          throwsA(error('forbidden')));
      f.service.hideContent(actor: f.alice, kind: 'message', contentId: msg.id);
      expect(
          f.service.messages(actor: f.bob, conversationId: space.defaultRoomId),
          isEmpty);
      expect(f.service.state.messages[msg.id]!.parts, text('original'));
      expect(
          f.service.state.events.any((e) => e.toJson()['id'] == original['id']),
          isTrue);
      final room = f.service.createRoom(
          actor: f.alice,
          spaceId: space.id,
          id: 'forum',
          title: '论坛',
          kind: 'forum');
      final post = f.service.createForumPost(
          actor: f.bob,
          roomId: room.id,
          title: 'post',
          parts: text('original post'));
      f.service.hideContent(actor: f.alice, kind: 'forum', contentId: post.id);
      expect(f.service.forumPosts(actor: f.bob, roomId: room.id), isEmpty);
      expect(
          () => f.service
              .messages(actor: f.bob, conversationId: post.conversationId),
          throwsA(error('forbidden')));
      expect(
          () => f.service.replyForumPost(
              actor: f.bob, postId: post.id, parts: text('reply')),
          throwsA(error('forbidden')));
      f.service.hideContent(
          actor: f.alice, kind: 'forum', contentId: post.id, hidden: false);
      expect(f.service.forumPosts(actor: f.bob, roomId: room.id).single.id,
          post.id);
    });
    test('社区owner可隐藏feed/comment，普通作者也不能撤回或隐藏私聊', () {
      final f = Fixture();
      final p = f.service
          .publishFeed(actor: f.bob, parts: text('feed'), visibility: 'public');
      final c = f.service
          .commentFeed(actor: f.alice, postId: p.id, parts: text('comment'));
      expect(
          () => f.service
              .hideContent(actor: f.bob, kind: 'feed', contentId: p.id),
          throwsA(error('forbidden')));
      f.service.hideContent(actor: f.alice, kind: 'comment', contentId: c.id);
      expect(f.service.feedComments(actor: f.bob, postId: p.id), isEmpty);
      f.service.hideContent(actor: f.alice, kind: 'feed', contentId: p.id);
      expect(f.service.feed(actor: f.bob), isEmpty);
      expect(f.service.state.feedPosts.containsKey(p.id), isTrue);
      expect(f.service.state.feedComments.containsKey(c.id), isTrue);
      f.service.addFriend(actor: f.alice, targetId: f.bob.id);
      final dm =
          f.service.directConversation(actor: f.alice, targetId: f.bob.id);
      final msg = f.service.sendMessage(
          actor: f.alice, conversationId: dm.id, parts: text('dm'));
      expect(
          () => f.service
              .hideContent(actor: f.alice, kind: 'message', contentId: msg.id),
          throwsA(error('forbidden')));
    });
  });

  group('历史资格区间与关系衰减', () {
    test('owner撤销许可同时撤销未完成续期票，另一方不能借旧票恢复', () {
      final f = Fixture();
      final (a, b, c) = f.botDm();
      f.service.leaveSpace(actor: f.bob, spaceId: 'space', botId: b.id);
      f.service.renewDirect(actor: f.alice, conversationId: c.id);
      f.service.permitBotDirect(
          actor: f.alice, botId: a.id, targetBotId: b.id, allow: false);
      f.service.renewDirect(actor: f.bob, conversationId: c.id);
      expect(
          () => f.service.sendMessage(
              actor: b, conversationId: c.id, parts: text('revoked vote')),
          throwsA(error('forbidden')));
      f.service.renewDirect(actor: f.alice, conversationId: c.id);
      expect(
          f.service
              .sendMessage(
                  actor: a, conversationId: c.id, parts: text('fresh approval'))
              .senderId,
          a.id);
    });
    test('默认新成员不能读加入前，退出后不能读未来或新房间，时间伪造不越权', () {
      final f = Fixture();
      final space = f.space();
      final before = f.service.sendMessage(
          actor: f.alice,
          conversationId: space.defaultRoomId,
          parts: text('before'));
      f.join(f.bob);
      f.time = DateTime.utc(2000);
      final during = f.service.sendMessage(
          actor: f.alice,
          conversationId: space.defaultRoomId,
          parts: text('during-old-clock'));
      expect(
          f.service
              .messages(actor: f.bob, conversationId: space.defaultRoomId)
              .map((m) => m.id),
          [during.id]);
      expect(() => f.service.message(actor: f.bob, messageId: before.id),
          throwsA(error('forbidden')));
      f.service.leaveSpace(actor: f.bob, spaceId: space.id);
      final after = f.service.sendMessage(
          actor: f.alice,
          conversationId: space.defaultRoomId,
          parts: text('after'));
      final room = f.service.createRoom(
          actor: f.alice, spaceId: space.id, id: 'new-room', title: 'new');
      expect(
          f.service.message(actor: f.bob, messageId: during.id).id, during.id);
      expect(() => f.service.message(actor: f.bob, messageId: after.id),
          throwsA(error('forbidden')));
      expect(() => f.service.messages(actor: f.bob, conversationId: room.id),
          throwsA(error('forbidden')));
      expect(f.service.conversations(actor: f.bob).map((c) => c.id),
          isNot(contains(room.id)));
    });
    test('再次加入不回填中间缺席区间，历史开放只允许首次显式领旧历史', () {
      final f = Fixture();
      final space =
          f.space(config: SpaceConfig(historyVisibleToNewMembers: true));
      final old = f.service.sendMessage(
          actor: f.alice,
          conversationId: space.defaultRoomId,
          parts: text('old'));
      f.join(f.bob);
      expect(f.service.message(actor: f.bob, messageId: old.id).id, old.id);
      f.service.leaveSpace(actor: f.bob, spaceId: space.id);
      final gap = f.service.sendMessage(
          actor: f.alice,
          conversationId: space.defaultRoomId,
          parts: text('gap'));
      f.join(f.bob);
      final current = f.service.sendMessage(
          actor: f.alice,
          conversationId: space.defaultRoomId,
          parts: text('current'));
      expect(
          f.service
              .messages(actor: f.bob, conversationId: space.defaultRoomId)
              .map((m) => m.id),
          [old.id, current.id]);
      expect(
          () => f.service.messages(
              actor: f.bob,
              conversationId: space.defaultRoomId,
              beforeId: gap.id),
          throwsA(error('not_found')));
      expect(() => f.service.message(actor: f.bob, messageId: gap.id),
          throwsA(error('forbidden')));
    });
    test('kick/ban和房间allowlist移除都只冻结未来，旧历史保留且重建一致', () {
      final f = Fixture();
      final space = f.space();
      f.join(f.bob);
      final old = f.service.sendMessage(
          actor: f.alice,
          conversationId: space.defaultRoomId,
          parts: text('old'));
      f.service.configureRoom(
          actor: f.alice,
          roomId: space.defaultRoomId,
          config: RoomConfig(allowedPrincipalIds: {'alice'}));
      final blocked = f.service.sendMessage(
          actor: f.alice,
          conversationId: space.defaultRoomId,
          parts: text('blocked'));
      expect(
          f.service
              .messages(actor: f.bob, conversationId: space.defaultRoomId)
              .single
              .id,
          old.id);
      f.service.configureRoom(
          actor: f.alice, roomId: space.defaultRoomId, config: RoomConfig());
      f.service.kick(actor: f.alice, spaceId: space.id, principalId: 'bob');
      f.join(f.bob);
      final again = f.service.sendMessage(
          actor: f.alice,
          conversationId: space.defaultRoomId,
          parts: text('again'));
      f.service.ban(
          actor: f.alice, spaceId: space.id, principalId: 'bob', banned: true);
      final later = f.service.sendMessage(
          actor: f.alice,
          conversationId: space.defaultRoomId,
          parts: text('later'));
      final restored = ChatService(ChatState.fromJson(
          jsonDecode(jsonEncode(f.service.state.toJson())) as JsonMap));
      final bob = restored.actor('bob');
      expect(
          restored
              .messages(actor: bob, conversationId: space.defaultRoomId)
              .map((m) => m.id),
          [old.id, again.id]);
      for (final msg in [blocked, later]) {
        expect(() => restored.message(actor: bob, messageId: msg.id),
            throwsA(error('forbidden')));
      }
      expect(() => restored.members(actor: bob, spaceId: space.id),
          throwsA(error('forbidden')));
    });
    test('论坛首帖资格与回复区间过滤，退出后已获线程可读但不可写', () {
      final f = Fixture();
      final space = f.space();
      final room = f.service.createRoom(
          actor: f.alice,
          spaceId: space.id,
          id: 'forum',
          title: '论坛',
          kind: 'forum');
      final before = f.service.createForumPost(
          actor: f.alice,
          roomId: room.id,
          title: 'before',
          parts: text('before'));
      f.join(f.bob);
      expect(f.service.forumPosts(actor: f.bob, roomId: room.id), isEmpty);
      expect(
          () => f.service
              .messages(actor: f.bob, conversationId: before.conversationId),
          throwsA(error('forbidden')));
      expect(
          () => f.service.replyForumPost(
              actor: f.bob, postId: before.id, parts: text('not visible')),
          throwsA(error('forbidden')));
      final during = f.service.createForumPost(
          actor: f.alice,
          roomId: room.id,
          title: 'during',
          parts: text('during'));
      f.service.replyForumPost(
          actor: f.bob, postId: during.id, parts: text('reply'));
      f.service.leaveSpace(actor: f.bob, spaceId: space.id);
      final later = f.service.replyForumPost(
          actor: f.alice, postId: during.id, parts: text('later'));
      expect(
          f.service
              .messages(actor: f.bob, conversationId: during.conversationId)
              .length,
          2);
      expect(f.service.forumPosts(actor: f.bob, roomId: room.id).single.id,
          during.id);
      expect(() => f.service.message(actor: f.bob, messageId: later.id),
          throwsA(error('forbidden')));
      expect(
          () => f.service.replyForumPost(
              actor: f.bob, postId: during.id, parts: text('left')),
          throwsA(error('forbidden')));
    });
    test('茶会使用同一原房间历史区间，离开后只能看旧茶会消息', () {
      final f = Fixture();
      final bot = f.bot(f.alice, 'bot');
      final space = f.space();
      f.join(f.alice, botId: bot.id);
      final shadow =
          f.service.state.rooms[space.defaultRoomId]!.shadowConversationId!;
      final before = f.service.sendMessage(
          actor: bot, conversationId: shadow, parts: text('before'));
      f.join(f.bob);
      final during = f.service.sendMessage(
          actor: bot, conversationId: shadow, parts: text('during'));
      f.service.leaveSpace(actor: f.bob, spaceId: space.id);
      final after = f.service.sendMessage(
          actor: bot, conversationId: shadow, parts: text('after'));
      expect(f.service.messages(actor: f.bob, conversationId: shadow).single.id,
          during.id);
      for (final msg in [before, after]) {
        expect(() => f.service.message(actor: f.bob, messageId: msg.id),
            throwsA(error('forbidden')));
      }
    });
  });

  group('完整持久化和重建', () {
    test('外部时间和生成器保证同一命令ID与无关既有事件数量无关', () {
      ChatService build({bool extra = false}) {
        var envelope = 'bootstrap';
        var sequence = 0;
        final service = ChatService(ChatState(),
            now: () => DateTime.utc(2026),
            idGenerator: (prefix) => '$prefix:$envelope:${sequence++}');
        service.registerAccount(
            id: 'alice', name: 'alice', displayName: 'Alice');
        final a = service.actor('alice');
        service.createSpace(
            actor: a, id: 'space', title: '空间', publicChannel: true);
        service.createRoom(
            actor: a,
            spaceId: 'space',
            id: 'forum',
            title: '论坛',
            kind: 'forum');
        if (extra) service.publishFeed(actor: a, parts: text('unrelated'));
        envelope = 'signed-source-event';
        sequence = 0;
        service.createForumPost(
            actor: a, roomId: 'forum', title: 'post', parts: text('stable'));
        return service;
      }

      final a = build();
      final b = build(extra: true);
      expect(a.state.forumPosts.values.single.toJson(),
          b.state.forumPosts.values.single.toJson());
      expect(a.state.messages.values.single.toJson(),
          b.state.messages.values.single.toJson());
      expect(a.state.events.last.id, b.state.events.last.id);
      expect(a.state.events.last.id, isNot(a.state.messages.values.single.id));
    });
    test('碰撞生成器拒绝且不提交任何部分业务变更', () {
      final f = Fixture();
      f.space();
      var prefixId = 'same';
      final service =
          ChatService(f.service.state, idGenerator: (_) => prefixId);
      final actor = service.actor('alice');
      final before = jsonEncode(service.state.toJson());
      expect(
          () => service.sendMessage(
              actor: actor,
              conversationId: 'space#main',
              parts: text('collision')),
          throwsA(error('conflict')));
      expect(jsonEncode(service.state.toJson()), before);
      prefixId = '';
      expect(() => service.publishFeed(actor: actor, parts: text('empty-id')),
          throwsA(error('bad_request')));
      expect(jsonEncode(service.state.toJson()), before);
    });
    test('不同服务的默认随机namespace避免离线生成同消息编号', () {
      final a = Fixture();
      final b = Fixture();
      final sa = a.space();
      final sb = b.space();
      final ma = a.service.sendMessage(
          actor: a.alice,
          conversationId: sa.defaultRoomId,
          parts: text('same'));
      final mb = b.service.sendMessage(
          actor: b.alice,
          conversationId: sb.defaultRoomId,
          parts: text('same'));
      expect(ma.id, isNot(mb.id));
    });
    test('所有索引、幂等、限流、双owner票、隐藏、关系、评论likes均由事件恢复', () {
      final f = Fixture(
          config: CommunityConfig(botMessagesPerHour: 4, maxDirectMessages: 2));
      final (a, b, c) = f.botDm();
      final msg = f.service.sendMessage(
          actor: a,
          conversationId: c.id,
          parts: text('persist'),
          idempotencyKey: 'once');
      f.service.leaveSpace(actor: f.bob, spaceId: 'space', botId: b.id);
      f.service.renewDirect(actor: f.alice, conversationId: c.id);
      f.service.addFriend(actor: f.alice, targetId: f.bob.id);
      final feed = f.service.publishFeed(actor: b, parts: text('friends'));
      final comment = f.service
          .commentFeed(actor: f.alice, postId: feed.id, parts: text('c'));
      f.service.likeFeed(actor: f.alice, postId: feed.id);
      f.service
          .hideContent(actor: f.alice, kind: 'comment', contentId: comment.id);
      f.service.mute(actor: f.alice, spaceId: 'space', principalId: 'bob');
      f.service.inviteToSpace(
          actor: f.alice, spaceId: 'space', principalId: 'carol');
      final snapshot =
          jsonDecode(jsonEncode(f.service.state.toJson())) as JsonMap;
      final restored =
          ChatService(ChatState.fromJson(snapshot), now: () => f.time);
      final aa = restored.actor(a.id);
      final bb = restored.actor(b.id);
      final alice = restored.actor('alice');
      final bob = restored.actor('bob');
      expect(restored.state.toJson(), f.service.state.toJson());
      expect(restored.messages(actor: alice, conversationId: c.id).single.id,
          msg.id);
      expect(
          restored
              .sendMessage(
                  actor: aa,
                  conversationId: c.id,
                  parts: text('persist'),
                  idempotencyKey: 'once')
              .id,
          msg.id);
      expect(
          () => restored.sendMessage(
              actor: aa,
              conversationId: c.id,
              parts: text('changed'),
              idempotencyKey: 'once'),
          throwsA(error('idempotency_conflict')));
      expect(
          () => restored.sendMessage(
              actor: bb, conversationId: c.id, parts: text('frozen')),
          throwsA(error('forbidden')));
      restored.renewDirect(actor: bob, conversationId: c.id);
      restored.sendMessage(
          actor: bb, conversationId: c.id, parts: text('resumed'));
      expect(restored.feedComments(actor: alice, postId: feed.id), isEmpty);
      expect(restored.feedLikes(actor: alice, postId: feed.id), {'alice'});
      expect(restored.friends(actor: aa).map((p) => p.id), contains('bob'));
      expect(
          restored
              .joinSpace(
                  actor: restored.actor('carol'),
                  spaceId: 'space',
                  invited: true)
              .status,
          'joined');
    });
    test('fromJson 拒绝版本错误、重复事件和无主bot，不将可写索引当真相', () {
      final f = Fixture();
      f.bot(f.alice, 'bot');
      final wrong = jsonDecode(jsonEncode(f.service.state.toJson())) as JsonMap;
      wrong['schemaVersion'] = 99;
      expect(() => ChatState.fromJson(wrong), throwsA(error('bad_request')));
      final duplicate =
          jsonDecode(jsonEncode(f.service.state.toJson())) as JsonMap;
      (duplicate['events'] as List).add((duplicate['events'] as List).first);
      expect(
          () => ChatState.fromJson(duplicate), throwsA(error('bad_request')));
      final orphan =
          jsonDecode(jsonEncode(f.service.state.toJson())) as JsonMap;
      final events = orphan['events'] as List;
      ((events.last as Map)['data']['bots'] as List).first['ownerId'] =
          'missing';
      expect(() => ChatState.fromJson(orphan), throwsA(error('bad_request')));
      final extra = jsonDecode(jsonEncode(f.service.state.toJson())) as JsonMap;
      extra['messages'] = {'forged': 'not authoritative'};
      expect(ChatState.fromJson(extra).messages, isEmpty);
    });
    test('幂等space/room/join/feed/forum/comment/like请求均不重复提交', () {
      final f = Fixture();
      final s = f.service;
      final space = s.createSpace(
          actor: f.alice,
          id: 's',
          title: 's',
          publicChannel: true,
          idempotencyKey: 's');
      expect(
          s
              .createSpace(
                  actor: f.alice,
                  id: 's',
                  title: 's',
                  publicChannel: true,
                  idempotencyKey: 's')
              .id,
          space.id);
      final room = s.createRoom(
          actor: f.alice,
          spaceId: 's',
          id: 'forum',
          title: 'f',
          kind: 'forum',
          idempotencyKey: 'r');
      expect(
          s
              .createRoom(
                  actor: f.alice,
                  spaceId: 's',
                  id: 'forum',
                  title: 'f',
                  kind: 'forum',
                  idempotencyKey: 'r')
              .id,
          room.id);
      final join = s.joinSpace(actor: f.bob, spaceId: 's', idempotencyKey: 'j');
      expect(
          s.joinSpace(actor: f.bob, spaceId: 's', idempotencyKey: 'j').toJson(),
          join.toJson());
      final p = s.createForumPost(
          actor: f.bob,
          roomId: room.id,
          title: 'post',
          parts: text('p'),
          idempotencyKey: 'p');
      expect(
          s
              .createForumPost(
                  actor: f.bob,
                  roomId: room.id,
                  title: 'post',
                  parts: text('p'),
                  idempotencyKey: 'p')
              .id,
          p.id);
      final reply = s.replyForumPost(
          actor: f.bob,
          postId: p.id,
          parts: text('r'),
          idempotencyKey: 'reply');
      expect(
          s
              .replyForumPost(
                  actor: f.bob,
                  postId: p.id,
                  parts: text('r'),
                  idempotencyKey: 'reply')
              .id,
          reply.id);
      final feed = s.publishFeed(
          actor: f.bob,
          parts: text('f'),
          visibility: 'public',
          idempotencyKey: 'f');
      expect(
          s
              .publishFeed(
                  actor: f.bob,
                  parts: text('f'),
                  visibility: 'public',
                  idempotencyKey: 'f')
              .id,
          feed.id);
      final comment = s.commentFeed(
          actor: f.alice,
          postId: feed.id,
          parts: text('c'),
          idempotencyKey: 'c');
      expect(
          s
              .commentFeed(
                  actor: f.alice,
                  postId: feed.id,
                  parts: text('c'),
                  idempotencyKey: 'c')
              .id,
          comment.id);
      s.likeFeed(actor: f.alice, postId: feed.id, idempotencyKey: 'l');
      final count = s.state.events.length;
      s.likeFeed(actor: f.alice, postId: feed.id, idempotencyKey: 'l');
      expect(s.state.events.length, count);
    });
  });
}
