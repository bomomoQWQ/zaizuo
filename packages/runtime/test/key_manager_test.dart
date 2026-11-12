import 'dart:convert';

import 'package:test/test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';
import 'package:zaizuo_runtime/src/key_manager.dart';

Matcher keyError(String code) =>
    isA<DomainException>().having((e) => e.code, 'code', code);
Map<String, dynamic> copyJson(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
List<JsonMap> text(String value) => [
      {
        'type': 'text',
        'data': {'text': value}
      }
    ];

final class KeyFixture {
  final Identity alice;
  final Identity bob;
  final Identity carol;
  final Identity mallory;
  final ChatService service;
  final Map<String, IdentityPublic> directory;
  late final ConversationKeyManager manager;
  KeyFixture._(this.alice, this.bob, this.carol, this.mallory, this.service,
      this.directory) {
    manager = fresh();
  }
  static Future<KeyFixture> create() async {
    final identities = await Future.wait(
        ['alice', 'bob', 'carol', 'mallory'].map(Identity.create));
    final service = ChatService(
        ChatState(communityOwnerId: identities.first.public.accountId),
        now: () => DateTime.utc(2026));
    for (final identity in identities) {
      service.registerAccount(
          id: identity.public.accountId,
          name: identity.public.name,
          displayName: identity.public.name);
    }
    return KeyFixture._(
        identities[0], identities[1], identities[2], identities[3], service, {
      for (final identity in identities)
        identity.public.accountId: identity.public
    });
  }

  ConversationKeyManager fresh(
          {String community = 'community',
          Map<String, IdentityPublic>? trust}) =>
      ConversationKeyManager(
          service: service,
          communityId: community,
          trustedAccounts: trust ?? directory);
  Actor who(Identity id) => service.actor(id.public.accountId);
  String id(Identity identity) => identity.public.accountId;
  SpaceRecord space({bool public = true, RoomConfig? roomConfig}) =>
      service.createSpace(
          actor: who(alice),
          id: 'space',
          title: '空间',
          publicChannel: public,
          defaultRoomConfig: roomConfig);
  void join(Identity owner, {String? botId}) =>
      service.joinSpace(actor: who(owner), spaceId: 'space', botId: botId);
  Actor bot(Identity owner, String id) {
    service.registerBot(actor: who(owner), id: id, displayName: id);
    return service.actor(id);
  }
}

void main() {
  late KeyFixture f;
  setUp(() async {
    f = await KeyFixture.create();
  });

  test('validateCurrentKey发送和重放前核对当前期次/策略/承诺，旧key只能解旧历史', () async {
    final space = f.space();
    await expectLater(
        f.manager.validateCurrentKey(
            key: ConversationKey.generate(space.defaultRoomId, 1)),
        throwsA(keyError('not_found')));
    final first = await f.manager
        .generate(sender: f.alice, conversationId: space.defaultRoomId);
    await f.manager.validateCurrentKey(key: first.key);
    await expectLater(
        f.manager.validateCurrentKey(
            key: ConversationKey.generate(space.defaultRoomId, 1)),
        throwsA(keyError('invalid_key')));
    f.join(f.bob);
    await expectLater(f.manager.validateCurrentKey(key: first.key),
        throwsA(keyError('stale_key')));
    final second = await f.manager
        .generate(sender: f.bob, conversationId: space.defaultRoomId);
    await f.manager.validateCurrentKey(key: second.key);
    await expectLater(f.manager.validateCurrentKey(key: first.key),
        throwsA(keyError('stale_key')));
  });

  test('control/feed保留scope不能被用户房间覆盖或未知scope降级', () async {
    f.space();
    for (final scope in [
      'control:community',
      'feed:${f.id(f.alice)}:private',
      'dm:fake',
      'message:fake'
    ]) {
      expect(
          () => f.service.createRoom(
              actor: f.who(f.alice), spaceId: 'space', id: scope, title: 'bad'),
          throwsA(keyError('bad_request')));
    }
    expect(() => f.manager.resolveAuthorizedRecipients('control:community'),
        throwsA(keyError('forbidden')));
    expect(
        () => f.manager
            .resolveAuthorizedRecipients('feed:${f.id(f.alice)}:secret'),
        throwsA(keyError('bad_request')));
    expect(
        f.manager
            .resolveAuthorizedRecipients('feed:${f.id(f.alice)}:private')
            .principalOwnerIds,
        {f.id(f.alice): f.id(f.alice)});
  });

  test('按可信历史名册revision复验旧public公告，latest增加账户必须轮换', () async {
    final old = {f.id(f.alice), f.id(f.bob)};
    final manager = ConversationKeyManager(
        service: f.service,
        communityId: 'community',
        trustedAccounts: f.directory,
        communityAccountIds: old);
    final scope = 'feed:${f.id(f.alice)}:public';
    final rotation =
        await manager.generate(sender: f.alice, conversationId: scope);
    final receiver = ConversationKeyManager(
        service: f.service,
        communityId: 'community',
        trustedAccounts: f.directory,
        communityAccountIds: old);
    await receiver.authorizeAnnouncement(announcement: rotation.announcement);
    await receiver.validateCurrentKey(key: rotation.key);
    expect(receiver.resolveAuthorizedRecipients(scope).accountIds, old);
    await expectLater(receiver.generate(sender: f.carol, conversationId: scope),
        throwsA(keyError('forbidden')));
    receiver.setCommunityAccounts(f.directory.keys.toSet());
    await expectLater(receiver.validateCurrentKey(key: rotation.key),
        throwsA(keyError('stale_key')));
    receiver.setCommunityAccounts(old);
    await receiver.validateCurrentKey(key: rotation.key);
    final snapshot = await ConversationKeyManager.fromJson(receiver.toJson(),
        service: f.service,
        communityId: 'community',
        trustedAccounts: f.directory,
        communityAccountIds: old);
    await snapshot.validateCurrentKey(key: rotation.key);
  });

  test('private公告不受无关新增名册账户影响，也不受无关好友操作污染', () async {
    final old = {f.id(f.alice), f.id(f.bob)};
    final manager = ConversationKeyManager(
        service: f.service,
        communityId: 'community',
        trustedAccounts: f.directory,
        communityAccountIds: old);
    final scope = 'feed:${f.id(f.alice)}:private';
    final original = manager.resolveAuthorizedRecipients(scope);
    final rotation =
        await manager.generate(sender: f.alice, conversationId: scope);
    manager.setCommunityAccounts(f.directory.keys.toSet());
    f.service.addFriend(actor: f.who(f.bob), targetId: f.id(f.carol));
    expect(manager.resolveAuthorizedRecipients(scope).policyToken,
        original.policyToken);
    await manager.validateCurrentKey(key: rotation.key);
    await expectLater(
        manager.issue(
            sender: f.alice,
            key: rotation.key,
            announcement: rotation.announcement,
            recipientPrincipalId: f.id(f.carol)),
        throwsA(keyError('forbidden')));
  });

  test('公开频道加入后任意当前成员分发，不需SU在线；公告可先授权再领取', () async {
    final space = f.space();
    f.join(f.bob);
    f.join(f.carol);
    final rotation = await f.manager
        .generate(sender: f.bob, conversationId: space.defaultRoomId);
    final receiver = f.fresh();
    await receiver.authorizeAnnouncement(announcement: rotation.announcement);
    final grant = await f.manager.issue(
        sender: f.bob,
        key: rotation.key,
        announcement: rotation.announcement,
        recipientPrincipalId: f.id(f.carol));
    final received = await receiver.receive(
        recipient: f.carol, grant: KeyGrant.fromJson(copyJson(grant.toJson())));
    expect(received.bytes, rotation.key.bytes);
    expect(received.epoch, 1);
    expect(receiver.currentAnnouncement(space.defaultRoomId)!.epoch, 1);
    expect(
        f.service.state.events.any((event) =>
            event.type.contains('key') ||
            event.type.contains('read') ||
            event.type.contains('online')),
        isFalse);
  });

  test('未加入/私域pending/退群/ban不能领新epoch，历史可读并不授新钥匙', () async {
    final space = f.space(public: false);
    final owner = f.who(f.alice);
    f.join(f.bob); // 私域pending
    var audience = f.manager.resolveAuthorizedRecipients(space.defaultRoomId);
    expect(audience.principalOwnerIds.containsKey(f.id(f.bob)), isFalse);
    final first = await f.manager
        .generate(sender: f.alice, conversationId: space.defaultRoomId);
    await expectLater(
        f.manager.issue(
            sender: f.alice,
            key: first.key,
            announcement: first.announcement,
            recipientPrincipalId: f.id(f.bob)),
        throwsA(keyError('forbidden')));
    f.service.decideJoin(
        actor: owner,
        spaceId: space.id,
        principalId: f.id(f.bob),
        approve: true);
    final msg = f.service.sendMessage(
        actor: owner, conversationId: space.defaultRoomId, parts: text('old'));
    final current = await f.manager
        .generate(sender: f.alice, conversationId: space.defaultRoomId);
    final grant = await f.manager.issue(
        sender: f.alice,
        key: current.key,
        announcement: current.announcement,
        recipientPrincipalId: f.id(f.bob));
    f.service.leaveSpace(actor: f.who(f.bob), spaceId: space.id);
    expect(
        f.service.message(actor: f.who(f.bob), messageId: msg.id).id, msg.id);
    final after = await f.manager
        .generate(sender: f.alice, conversationId: space.defaultRoomId);
    await expectLater(
        f.manager.issue(
            sender: f.alice,
            key: after.key,
            announcement: after.announcement,
            recipientPrincipalId: f.id(f.bob)),
        throwsA(keyError('forbidden')));
    await expectLater(f.fresh().receive(recipient: f.bob, grant: grant),
        throwsA(keyError('stale_key')));
    await expectLater(
        f.manager.generate(sender: f.bob, conversationId: space.defaultRoomId),
        throwsA(keyError('forbidden')));
    f.service.ban(
        actor: owner,
        spaceId: space.id,
        principalId: f.id(f.bob),
        banned: true);
    expect(
        f.manager
            .resolveAuthorizedRecipients(space.defaultRoomId)
            .principalOwnerIds
            .containsKey(f.id(f.bob)),
        isFalse);
  });

  test('新成员默认false必须生成新epoch；同旧key不能靠名单更新伪历史隔离', () async {
    final space = f.space();
    final first = await f.manager
        .generate(sender: f.alice, conversationId: space.defaultRoomId);
    f.join(f.bob);
    await expectLater(
        f.manager.issue(
            sender: f.alice,
            key: first.key,
            announcement: first.announcement,
            recipientPrincipalId: f.id(f.bob)),
        throwsA(keyError('stale_key')));
    final second = await f.manager
        .generate(sender: f.alice, conversationId: space.defaultRoomId);
    expect(second.key.epoch, 2);
    expect(second.key.bytes, isNot(first.key.bytes));
    final grant = await f.manager.issue(
        sender: f.alice,
        key: second.key,
        announcement: second.announcement,
        recipientPrincipalId: f.id(f.bob));
    expect((await f.fresh().receive(recipient: f.bob, grant: grant)).bytes,
        second.key.bytes);
    final before = (copyJson(second.announcement.toJson())['body']
        as Map<String, dynamic>);
    before['epoch'] = 3;
    before['key_commitment'] = await objectHash({
      'domain': 'zaizuo.conversation.key_commitment.v1',
      'community': 'community',
      'conversation': space.defaultRoomId,
      'epoch': 3,
      'key': base64Encode(second.key.bytes)
    });
    final reused = KeyEpochAnnouncement.fromJson(
        {'body': before, 'signature': await f.alice.sign(before)});
    await expectLater(f.manager.authorizeAnnouncement(announcement: reused),
        throwsA(keyError('invalid_key')));
  });

  test('退群重入即使audience恢复相同也拒旧公告，授权事件水位防旧epoch复用', () async {
    final space = f.space();
    f.join(f.bob);
    final first = await f.manager
        .generate(sender: f.alice, conversationId: space.defaultRoomId);
    final original = f.manager.resolveAuthorizedRecipients(space.defaultRoomId);
    f.service.leaveSpace(actor: f.who(f.bob), spaceId: space.id);
    f.join(f.bob);
    final rejoined = f.manager.resolveAuthorizedRecipients(space.defaultRoomId);
    expect(rejoined.principalOwnerIds, original.principalOwnerIds);
    expect(rejoined.policyToken, isNot(original.policyToken));
    await expectLater(
        f.manager.issue(
            sender: f.alice,
            key: first.key,
            announcement: first.announcement,
            recipientPrincipalId: f.id(f.bob)),
        throwsA(keyError('stale_key')));
  });

  test('聊天室/shadow/forum房间/帖子支持当前房间allowlist和ban、bot-owner映射', () async {
    final b = f.bot(f.bob, 'b-bot');
    final space = f.space();
    f.join(f.bob, botId: b.id);
    f.join(f.carol);
    final shadow = '${space.defaultRoomId}#shadow';
    final chat = f.manager.resolveAuthorizedRecipients(space.defaultRoomId);
    final tea = f.manager.resolveAuthorizedRecipients(shadow);
    expect(tea.principalOwnerIds, chat.principalOwnerIds);
    expect(tea.principalOwnerIds[b.id], f.id(f.bob));
    expect(tea.principalOwnerIds.containsKey(f.id(f.bob)),
        isFalse); // owner未入空间，不能借bot多收principal权限
    final room = f.service.createRoom(
        actor: f.who(f.alice),
        spaceId: space.id,
        id: 'forum',
        title: '论坛',
        kind: 'forum');
    final post = f.service.createForumPost(
        actor: b, roomId: room.id, title: 'post', parts: text('post'));
    expect(f.manager.resolveAuthorizedRecipients(room.id).principalOwnerIds,
        chat.principalOwnerIds);
    expect(
        f.manager
            .resolveAuthorizedRecipients(post.conversationId)
            .principalOwnerIds,
        chat.principalOwnerIds);
    f.service.ban(
        actor: f.who(f.alice),
        spaceId: space.id,
        roomId: room.id,
        principalId: b.id,
        banned: true);
    expect(
        f.manager
            .resolveAuthorizedRecipients(room.id)
            .principalOwnerIds
            .containsKey(b.id),
        isFalse);
    f.service.configureRoom(
        actor: f.who(f.alice),
        roomId: space.defaultRoomId,
        config: RoomConfig(allowedPrincipalIds: {f.id(f.alice)}));
    expect(f.manager.resolveAuthorizedRecipients(shadow).principalOwnerIds.keys,
        [f.id(f.alice)]);
  });

  test('bot only in room可由其owner账户分发但不继承发消息/社交权限', () async {
    final b = f.bot(f.bob, 'b-bot');
    final space = f.space();
    f.join(f.bob, botId: b.id);
    final rotation = await f.manager
        .generate(sender: f.bob, conversationId: space.defaultRoomId);
    final grant = await f.manager.issue(
        sender: f.bob,
        key: rotation.key,
        announcement: rotation.announcement,
        recipientPrincipalId: b.id);
    expect(grant.recipientAccountId, f.id(f.bob));
    expect(grant.recipientPrincipalId, b.id);
    expect((await f.fresh().receive(recipient: f.bob, grant: grant)).bytes,
        rotation.key.bytes);
    expect(
        () => f.service.sendMessage(
            actor: f.who(f.bob),
            conversationId: space.defaultRoomId,
            parts: text('owner not member')),
        throwsA(keyError('forbidden')));
    expect(() => f.service.joinSpace(actor: b, spaceId: space.id),
        throwsA(keyError('forbidden')));
  });

  test('bot-bot DM只两bot和双方owner可收，旁观owner额外授权key但不能发言', () async {
    final a = f.bot(f.alice, 'a-bot');
    final b = f.bot(f.bob, 'b-bot');
    f.space();
    f.join(f.alice, botId: a.id);
    f.join(f.bob, botId: b.id);
    final dm = f.service.directConversation(actor: a, targetId: b.id);
    final audience = f.manager.resolveAuthorizedRecipients(dm.id);
    expect(audience.principalOwnerIds.keys.toSet(),
        {a.id, b.id, f.id(f.alice), f.id(f.bob)});
    final rotation =
        await f.manager.generate(sender: f.alice, conversationId: dm.id);
    final ownerGrant = await f.manager.issue(
        sender: f.alice,
        key: rotation.key,
        announcement: rotation.announcement,
        recipientPrincipalId: f.id(f.bob));
    expect((await f.fresh().receive(recipient: f.bob, grant: ownerGrant)).bytes,
        rotation.key.bytes);
    await expectLater(
        f.manager.issue(
            sender: f.alice,
            key: rotation.key,
            announcement: rotation.announcement,
            recipientPrincipalId: f.id(f.carol)),
        throwsA(keyError('forbidden')));
    expect(
        () => f.service.sendMessage(
            actor: f.who(f.bob),
            conversationId: dm.id,
            parts: text('observer')),
        throwsA(keyError('forbidden')));
    f.service.leaveSpace(actor: f.who(f.bob), spaceId: 'space', botId: b.id);
    expect(f.manager.resolveAuthorizedRecipients(dm.id).principalOwnerIds,
        audience.principalOwnerIds);
    final still = f.fresh();
    await still.authorizeAnnouncement(
        announcement: rotation.announcement); // frozen write不撤旧历史收钥匙
    expect(
        () => f.service.sendMessage(
            actor: b, conversationId: dm.id, parts: text('frozen')),
        throwsA(keyError('forbidden')));
  });

  test('人-bot DM不自动给bot owner旁观principal，其他secret/未知scope全拒', () async {
    final b = f.bot(f.bob, 'b-bot');
    f.service.addFriend(actor: f.who(f.alice), targetId: f.id(f.bob));
    final dm =
        f.service.directConversation(actor: f.who(f.alice), targetId: b.id);
    final audience = f.manager.resolveAuthorizedRecipients(dm.id);
    expect(audience.principalOwnerIds.keys.toSet(), {f.id(f.alice), b.id});
    expect(
        audience.accountIds, {f.id(f.alice), f.id(f.bob)}); // bot的实际解锁仍归owner账户
    for (final scope in [
      'secret',
      'control:community',
      'feed:missing',
      'feed:${f.id(f.alice)}:all'
    ]) {
      expect(() => f.manager.resolveAuthorizedRecipients(scope),
          throwsA(isA<DomainException>()));
    }
  });

  test('feed public/friends/private按domain对称可见性，private bot不额外赋owner主体',
      () async {
    final b = f.bot(f.bob, 'b-bot');
    f.bot(f.alice, 'draft-active');
    f.service
        .createBotDraft(actor: f.who(f.alice), id: 'draft', displayName: '草案');
    final private =
        f.manager.resolveAuthorizedRecipients('feed:${b.id}:private');
    expect(private.principalOwnerIds, {b.id: f.id(f.bob)});
    expect(private.principalOwnerIds.containsKey(f.id(f.bob)), isFalse);
    var friends = f.manager.resolveAuthorizedRecipients('feed:${b.id}:friends');
    expect(friends.accountIds, contains(f.id(f.bob)));
    expect(friends.accountIds, isNot(contains(f.id(f.alice))));
    f.service.addFriend(actor: f.who(f.alice), targetId: f.id(f.bob));
    friends = f.manager.resolveAuthorizedRecipients('feed:${b.id}:friends');
    expect(friends.accountIds, contains(f.id(f.alice)));
    final public = f.manager.resolveAuthorizedRecipients('feed:${b.id}:public');
    expect(public.accountIds, f.directory.keys.toSet());
    expect(public.principalOwnerIds.containsKey('draft'), isFalse);
    f.service.removeFriend(actor: f.who(f.alice), targetId: f.id(f.bob));
    expect(
        f.manager
            .resolveAuthorizedRecipients('feed:${b.id}:friends')
            .accountIds,
        isNot(contains(f.id(f.alice))));
  });

  test('feed删好友后旧epoch不能发给原朋友；private不能发给无关账号', () async {
    final scope = 'feed:${f.id(f.alice)}:friends';
    f.service.addFriend(actor: f.who(f.alice), targetId: f.id(f.bob));
    final rotation =
        await f.manager.generate(sender: f.alice, conversationId: scope);
    f.service.removeFriend(actor: f.who(f.alice), targetId: f.id(f.bob));
    await expectLater(
        f.manager.issue(
            sender: f.alice,
            key: rotation.key,
            announcement: rotation.announcement,
            recipientPrincipalId: f.id(f.bob)),
        throwsA(keyError('stale_key')));
    final private = await f.manager.generate(
        sender: f.alice, conversationId: 'feed:${f.id(f.alice)}:private');
    await expectLater(
        f.manager.issue(
            sender: f.alice,
            key: private.key,
            announcement: private.announcement,
            recipientPrincipalId: f.id(f.bob)),
        throwsA(keyError('forbidden')));
  });

  test('cap history.read撤销使bot不能领新key；mute不改只读资格', () async {
    final b = f.bot(f.bob, 'b-bot');
    final space = f.space();
    f.join(f.bob, botId: b.id);
    final initial = f.manager.resolveAuthorizedRecipients(space.defaultRoomId);
    f.service.mute(actor: f.who(f.alice), spaceId: space.id, principalId: b.id);
    expect(
        f.manager.resolveAuthorizedRecipients(space.defaultRoomId).policyToken,
        initial.policyToken);
    f.service.setBotCaps(
        actor: f.who(f.bob), botId: b.id, caps: {BotCapability.sendMessage});
    expect(
        f.manager
            .resolveAuthorizedRecipients(space.defaultRoomId)
            .principalOwnerIds
            .containsKey(b.id),
        isFalse);
  });

  test('独立随机epoch、已知回退拒绝、同epoch不同key锁止后不能偷偷继续', () async {
    final space = f.space();
    f.join(f.bob);
    final first = await f.manager
        .generate(sender: f.alice, conversationId: space.defaultRoomId);
    final competing = await f
        .fresh()
        .generate(sender: f.bob, conversationId: space.defaultRoomId);
    expect(first.key.epoch, competing.key.epoch);
    expect(first.key.bytes, isNot(competing.key.bytes));
    await expectLater(
        f.manager.authorizeAnnouncement(announcement: competing.announcement),
        throwsA(keyError('epoch_conflict')));
    expect(f.manager.conflictedConversations, {space.defaultRoomId});
    await expectLater(
        f.manager
            .generate(sender: f.alice, conversationId: space.defaultRoomId),
        throwsA(keyError('epoch_conflict')));
    final restored = await ConversationKeyManager.fromJson(
        copyJson(f.manager.toJson()),
        service: f.service,
        communityId: 'community',
        trustedAccounts: f.directory);
    expect(restored.conflictedConversations, {space.defaultRoomId});
    await expectLater(
        restored.generate(sender: f.alice, conversationId: space.defaultRoomId),
        throwsA(keyError('epoch_conflict')));
    final normal = f.fresh();
    await normal.authorizeAnnouncement(announcement: first.announcement);
    final next = await normal.generate(
        sender: f.bob, conversationId: space.defaultRoomId);
    expect(next.key.epoch, 2);
    expect(next.key.bytes, isNot(first.key.bytes));
    await expectLater(
        normal.authorizeAnnouncement(announcement: first.announcement),
        throwsA(keyError('stale_key')));
  });

  test('metadata快照恢复公告但无明文key或私钥，不靠JSON恢复授权', () async {
    final space = f.space();
    f.join(f.bob);
    final rotation = await f.manager
        .generate(sender: f.alice, conversationId: space.defaultRoomId);
    final json = copyJson(f.manager.toJson());
    final serialized = jsonEncode(json);
    expect(serialized, isNot(contains(base64Encode(rotation.key.bytes))));
    expect(serialized, isNot(contains('signing_seed')));
    expect(serialized, isNot(contains('exchange_seed')));
    final restored = await ConversationKeyManager.fromJson(json,
        service: f.service,
        communityId: 'community',
        trustedAccounts: f.directory);
    expect(restored.currentAnnouncement(space.defaultRoomId)!.toJson(),
        rotation.announcement.toJson());
    final next = await restored.generate(
        sender: f.bob, conversationId: space.defaultRoomId);
    expect(next.key.epoch, 2);
    final tampered = copyJson(json);
    ((tampered['announcements'] as List).first['body'] as Map)['epoch'] = 10;
    await expectLater(
        ConversationKeyManager.fromJson(tampered,
            service: f.service,
            communityId: 'community',
            trustedAccounts: f.directory),
        throwsA(keyError('forbidden')));
  });

  test('签名sender必须是钉住的现成员，信封不能自报新公钥/同名替身', () async {
    final space = f.space();
    f.join(f.bob);
    await expectLater(
        f.manager
            .generate(sender: f.mallory, conversationId: space.defaultRoomId),
        throwsA(keyError('forbidden')));
    final replacement = await Identity.create('bob');
    expect(replacement.public.accountId, f.id(f.bob));
    await expectLater(
        f.manager
            .generate(sender: replacement, conversationId: space.defaultRoomId),
        throwsA(keyError('forbidden')));
    final rotation = await f.manager
        .generate(sender: f.alice, conversationId: space.defaultRoomId);
    final sparse = f.fresh(trust: {f.id(f.bob): f.bob.public});
    await expectLater(
        sparse.authorizeAnnouncement(announcement: rotation.announcement),
        throwsA(keyError('forbidden')));
    final forgedBody = copyJson(rotation.announcement.toJson())['body']
        as Map<String, dynamic>;
    forgedBody['issuer'] = f.id(f.bob);
    final forged = KeyEpochAnnouncement.fromJson(
        {'body': forgedBody, 'signature': await replacement.sign(forgedBody)});
    await expectLater(f.fresh().authorizeAnnouncement(announcement: forged),
        throwsA(keyError('forbidden')));
  });

  test('grant收件人、社区、外层签名、内封装签名和key承诺都被核对', () async {
    final space = f.space();
    f.join(f.bob);
    f.join(f.carol);
    final rotation = await f.manager
        .generate(sender: f.alice, conversationId: space.defaultRoomId);
    final grant = await f.manager.issue(
        sender: f.alice,
        key: rotation.key,
        announcement: rotation.announcement,
        recipientPrincipalId: f.id(f.bob));
    await expectLater(f.fresh().receive(recipient: f.carol, grant: grant),
        throwsA(keyError('forbidden')));
    await expectLater(
        f.fresh(community: 'another').receive(recipient: f.bob, grant: grant),
        throwsA(keyError('forbidden')));
    final tampered = copyJson(grant.toJson());
    (tampered['body'] as Map)['recipient_principal'] = f.id(f.carol);
    await expectLater(
        f.fresh().receive(recipient: f.bob, grant: KeyGrant.fromJson(tampered)),
        throwsA(keyError('forbidden')));
    final body = copyJson(grant.toJson())['body'] as Map<String, dynamic>;
    final inner = body['envelope'] as Map<String, dynamic>;
    (inner['body'] as Map)['recipient'] = f.id(f.carol);
    final innerTampered = KeyGrant.fromJson(
        {'body': body, 'signature': await f.alice.sign(body)});
    await expectLater(f.fresh().receive(recipient: f.bob, grant: innerTampered),
        throwsA(keyError('invalid_key')));
    final wrong =
        ConversationKey.generate(space.defaultRoomId, rotation.key.epoch);
    await expectLater(
        f.manager.issue(
            sender: f.alice,
            key: wrong,
            announcement: rotation.announcement,
            recipientPrincipalId: f.id(f.bob)),
        throwsA(keyError('invalid_key')));
  });

  test('公告/recipient签名JSON深不可变，不因调用者改原map而改变授权', () async {
    final space = f.space();
    f.join(f.bob);
    final rotation = await f.manager
        .generate(sender: f.alice, conversationId: space.defaultRoomId);
    final original = copyJson(rotation.announcement.toJson());
    final announcement = KeyEpochAnnouncement.fromJson(original);
    (original['body'] as Map)['epoch'] = 999;
    expect(announcement.epoch, 1);
    expect(() => (announcement.body['principals'] as Map).clear(),
        throwsUnsupportedError);
    final grant = await f.manager.issue(
        sender: f.alice,
        key: rotation.key,
        announcement: announcement,
        recipientPrincipalId: f.id(f.bob));
    expect(
        () => (grant.body['envelope'] as Map).clear(), throwsUnsupportedError);
    expect(() => f.manager.trustedAccounts.clear(), throwsUnsupportedError);
    expect(
        () => f.manager
            .resolveAuthorizedRecipients(space.defaultRoomId)
            .principalOwnerIds
            .clear(),
        throwsUnsupportedError);
  });
}
