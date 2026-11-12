// 独立评审回归：只描述安全期望，不更改生产实现。
import 'dart:io';

import 'package:test/test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';
import 'package:zaizuo_runtime/zaizuo_runtime.dart';

final class ReviewFixture {
  final Identity alice;
  final Identity bob;
  final DeviceCredentials aliceDevice;
  final DeviceCredentials bobDevice;
  final TrustStore trust;
  final ChatState seed;
  final ConversationKey control;
  ReviewFixture(this.alice, this.bob, this.aliceDevice, this.bobDevice,
      this.trust, this.seed, this.control);
  static Future<ReviewFixture> create() async {
    final alice = await Identity.create('alice');
    final bob = await Identity.create('bob');
    final ad = await DeviceCredentials.create();
    final bd = await DeviceCredentials.create();
    await ad.authorize(alice, 'review');
    await bd.authorize(bob, 'review');
    final trust = TrustStore('review')
      ..trustAccount(alice.public)
      ..trustAccount(bob.public);
    await trust.authorizeDevice(ad.certificate!);
    await trust.authorizeDevice(bd.certificate!);
    final seed = ChatState(communityOwnerId: alice.public.accountId);
    var i = 0;
    final s = ChatService(seed,
        idGenerator: (prefix) => '$prefix:review-seed:${i++}');
    s.registerAccount(
        id: alice.public.accountId, name: 'alice', displayName: 'Alice');
    s.registerAccount(
        id: bob.public.accountId, name: 'bob', displayName: 'Bob');
    s.createSpace(
        actor: s.actor(alice.public.accountId),
        id: 'room-space',
        title: 'room',
        publicChannel: true);
    s.joinSpace(actor: s.actor(bob.public.accountId), spaceId: 'room-space');
    await s.close();
    return ReviewFixture(alice, bob, ad, bd, trust, seed,
        ConversationKey.generate('control:review', 1));
  }

  Future<FileEventStore> store() async {
    final temp =
        await Directory.systemTemp.createTemp('zaizuo-security-review-');
    addTearDown(() => temp.delete(recursive: true));
    final result = await FileEventStore.open(temp, trust);
    addTearDown(result.close);
    return result;
  }

  ConversationKeyManager manager() => ConversationKeyManager(
      service: ChatService(seed),
      communityId: 'review',
      trustedAccounts: trust.accounts);
  JsonMap command(String actor, String op, JsonMap params) => {
        'version': 1,
        'manifest_revision': 1,
        'actor': actor,
        'operation': op,
        'params': params
      };
}

void main() {
  test('旧profile发钥接口只接受exact control，不可绕过manager给离群者最新room key', () async {
    final root =
        await Directory.systemTemp.createTemp('zaizuo-review-profile-');
    addTearDown(() => root.delete(recursive: true));
    const password = 'R7!mK2@wX9#vT4%p';
    await LocalProfile.initialize(root,
        name: 'alice',
        displayName: 'Alice',
        password: password,
        parameters:
            const KdfParameters(memoryKiB: 32, iterations: 1, parallelism: 1));
    final profile = await LocalProfile.open(root, password);
    final state =
        ChatState(communityOwnerId: profile.identity.public.accountId);
    final s = ChatService(state);
    final bob = await Identity.create('bob');
    s.registerAccount(
        id: profile.identity.public.accountId,
        name: 'alice',
        displayName: 'Alice');
    s.registerAccount(
        id: bob.public.accountId, name: 'bob', displayName: 'Bob');
    final alice = s.actor(profile.identity.public.accountId);
    final b = s.actor(bob.public.accountId);
    s.createSpace(
        actor: alice, id: 'room-space', title: 'room', publicChannel: true);
    s.joinSpace(actor: b, spaceId: 'room-space');
    s.leaveSpace(actor: b, spaceId: 'room-space');
    expect(s.canReadConversation(actor: b, conversationId: 'room-space#main'),
        isTrue);
    final roomKey = ConversationKey.generate('room-space#main', 2);
    await expectLater(
        profile.grantKey(key: roomKey, recipient: bob.public, state: state),
        throwsStateError);
    await expectLater(
        profile.grantKey(
            key: ConversationKey.generate('control:another-community', 1),
            recipient: profile.identity.public,
            state: state),
        throwsStateError);
    final bypass = await roomKey.wrapFor(bob.public,
        sender: profile.identity, communityId: profile.manifest.communityId);
    await expectLater(profile.withGrants([bypass]), throwsStateError);
    await s.close();
  });
  test('保留scope不能作为房间ID：否则私房消息会直接用全社区control key', () async {
    final f = await ReviewFixture.create();
    final store = await f.store();
    final replica = await EncryptedReplica.open(
        store: store,
        device: f.aliceDevice,
        seed: f.seed,
        identity: f.alice,
        keys: [f.control]);
    addTearDown(replica.close);
    await expectLater(
        replica.execute(
            actorId: f.alice.public.accountId,
            operation: 'space.create',
            params: {
              'id': 'secret-space',
              'title': '私房',
              'public_channel': false,
              'default_room_id': 'control:review'
            },
            conversation: 'control:review'),
        throwsA(isA<DomainException>()));
  });

  test('保留feed scope不能作为房间ID，防room成员拿到另一作者private feed key', () async {
    final f = await ReviewFixture.create();
    final store = await f.store();
    final replica = await EncryptedReplica.open(
        store: store,
        device: f.bobDevice,
        seed: f.seed,
        identity: f.bob,
        keys: [f.control]);
    addTearDown(replica.close);
    await expectLater(
        replica.execute(
            actorId: f.bob.public.accountId,
            operation: 'space.create',
            params: {
              'id': 'malicious-space',
              'title': '碰撞',
              'public_channel': true,
              'default_room_id': 'feed:${f.alice.public.accountId}:private'
            },
            conversation: 'control:review'),
        throwsA(isA<DomainException>()));
  });

  test('无Identity不能跳过当期验证继续给离群人可解的旧epoch发未来消息', () async {
    final f = await ReviewFixture.create();
    final store = await f.store();
    final manager = f.manager();
    final rotation = await manager.generate(
        sender: f.alice, conversationId: 'room-space#main');
    await store.append(
        device: f.aliceDevice,
        key: f.control,
        body: f.command(f.alice.public.accountId, 'key.rotate',
            {'announcement': rotation.announcement.toJson()}));
    await store.append(
        device: f.bobDevice,
        key: f.control,
        body: f.command(
            f.bob.public.accountId, 'space.leave', {'space': 'room-space'}));
    final replica = await EncryptedReplica.open(
        store: store,
        device: f.aliceDevice,
        seed: f.seed,
        keys: [f.control, rotation.key]);
    addTearDown(replica.close);
    await expectLater(
        replica.execute(
            actorId: f.alice.public.accountId,
            operation: 'message.send',
            params: {
              'conversation': 'room-space#main',
              'parts': [
                {
                  'type': 'text',
                  'data': {'text': 'future-after-bob-left'}
                }
              ]
            },
            conversation: 'room-space#main'),
        throwsA(isA<DomainException>()));
  });

  test('晚到recipient grant应在单次open自动补重放先前合法content', () async {
    final f = await ReviewFixture.create();
    final store = await f.store();
    final manager = f.manager();
    final rotation = await manager.generate(
        sender: f.alice, conversationId: 'room-space#main');
    final grant = await manager.issue(
        sender: f.alice,
        key: rotation.key,
        announcement: rotation.announcement,
        recipientPrincipalId: f.bob.public.accountId);
    await store.append(
        device: f.aliceDevice,
        key: f.control,
        body: f.command(f.alice.public.accountId, 'key.rotate',
            {'announcement': rotation.announcement.toJson()}));
    await store.append(
        device: f.aliceDevice,
        key: rotation.key,
        body: f.command(f.alice.public.accountId, 'message.send', {
          'conversation': 'room-space#main',
          'parts': [
            {
              'type': 'text',
              'data': {'text': 'before-late-grant'}
            }
          ]
        }));
    await store.append(
        device: f.aliceDevice,
        key: f.control,
        body: f.command(
            f.alice.public.accountId, 'key.grant', {'grant': grant.toJson()}));
    final replica = await EncryptedReplica.open(
        store: store,
        device: f.bobDevice,
        seed: f.seed,
        identity: f.bob,
        keys: [f.control]);
    addTearDown(replica.close);
    expect(
        replica.service
            .messages(
                actor: replica.service.actor(f.bob.public.accountId),
                conversationId: 'room-space#main')
            .length,
        1);
  });
}
