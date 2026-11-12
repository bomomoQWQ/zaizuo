import 'dart:io';

import 'package:test/test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';
import 'package:zaizuo_runtime/zaizuo_runtime.dart';

typedef Fixture = ({
  Identity identity,
  Identity other,
  DeviceCredentials device,
  TrustStore trust,
  ChatState seed,
  List<ConversationKey> keys,
  KeyEpochAnnouncement announcement,
  List<KeyGrant> grants,
  String botId
});

void main() {
  test('已签名但错误AEAD的事件隔离，不阻塞后续正常消息', () async {
    final fixture = await build();
    final root = await Directory.systemTemp.createTemp('zaizuo-bad-aead-');
    addTearDown(() => root.delete(recursive: true));
    final store = await FileEventStore.open(root, fixture.trust);
    await prime(store, fixture);
    final bad = await store.append(
        device: fixture.device,
        key: ConversationKey.generate('public#main', 1),
        body: command(fixture.botId, 'bad'));
    final replica = await EncryptedReplica.open(
        store: store,
        device: fixture.device,
        seed: fixture.seed,
        keys: fixture.keys);
    expect(replica.rejected[bad.id], 'invalid_command');
    final good = await replica.execute(
        actorId: fixture.botId,
        operation: 'message.send',
        params: parameters('good'),
        conversation: 'public#main');
    expect(
        replica.service
            .message(
                actor: replica.service.actor(fixture.botId),
                messageId: (good['result'] as Map)['id'] as String)
            .parts
            .single['data']['text'],
        'good');
    await replica.close();
    await store.close();
  });
  test('无解锁Identity的客户端仍须验证期次，重启复现ID', () async {
    final fixture = await build();
    final root = await Directory.systemTemp.createTemp('zaizuo-replica-');
    addTearDown(() => root.delete(recursive: true));
    final store = await FileEventStore.open(root, fixture.trust);
    await prime(store, fixture);
    final replica = await EncryptedReplica.open(
        store: store,
        device: fixture.device,
        seed: fixture.seed,
        keys: fixture.keys);
    final result = await replica.execute(
        actorId: fixture.botId,
        operation: 'message.send',
        params: parameters('在座已上线'),
        conversation: 'public#main');
    final id = (result['result'] as Map)['id'] as String;
    final count = store.allEnvelopes.length;
    await expectLater(
        replica.execute(
            actorId: fixture.botId,
            operation: 'space.create',
            params: {'id': 'evil', 'title': 'evil', 'public_channel': true},
            conversation: 'control:community'),
        throwsA(isA<DomainException>()));
    expect(store.allEnvelopes.length, count);
    await replica.close();
    await store.close();
    final reopened = await FileEventStore.open(root, fixture.trust);
    final restored = await EncryptedReplica.open(
        store: reopened,
        device: fixture.device,
        seed: fixture.seed,
        keys: fixture.keys);
    expect(
        restored.service
            .message(
                actor: restored.service.actor(fixture.botId), messageId: id)
            .parts
            .single['data']['text'],
        '在座已上线');
    expect(restored.rejected, isEmpty);
    await restored.close();
    await reopened.close();
  });
  test('签名者不能借actor冒充另一主账户', () async {
    final fixture = await build();
    final root = await Directory.systemTemp.createTemp('zaizuo-actor-');
    addTearDown(() => root.delete(recursive: true));
    final store = await FileEventStore.open(root, fixture.trust);
    await prime(store, fixture);
    final attacker = await store.append(
        device: fixture.device,
        key: fixture.keys.last,
        body: command(fixture.other.public.accountId, '伪造'));
    final replica = await EncryptedReplica.open(
        store: store,
        device: fixture.device,
        seed: fixture.seed,
        keys: fixture.keys);
    expect(replica.rejected[attacker.id], 'forbidden');
    expect(replica.service.state.messages, isEmpty);
    await replica.close();
    await store.close();
  });
  test('正文不能伪装控制通道写入向全社区泄露', () async {
    final fixture = await build();
    final root = await Directory.systemTemp.createTemp('zaizuo-route-');
    addTearDown(() => root.delete(recursive: true));
    final store = await FileEventStore.open(root, fixture.trust);
    await prime(store, fixture);
    final replica = await EncryptedReplica.open(
        store: store,
        device: fixture.device,
        seed: fixture.seed,
        keys: fixture.keys);
    final count = store.allEnvelopes.length;
    await expectLater(
        replica.execute(
            actorId: fixture.botId,
            operation: 'message.send',
            params: parameters('secret'),
            conversation: 'control:community'),
        throwsA(isA<DomainException>()));
    expect(store.allEnvelopes.length, count);
    await replica.close();
    await store.close();
  });
  test('没有公告不能靠不传Identity跳过当期验证', () async {
    final fixture = await build();
    final root = await Directory.systemTemp.createTemp('zaizuo-no-epoch-');
    addTearDown(() => root.delete(recursive: true));
    final store = await FileEventStore.open(root, fixture.trust);
    final bad = await store.append(
        device: fixture.device,
        key: fixture.keys.last,
        body: command(fixture.botId, '未获公告'));
    final replica = await EncryptedReplica.open(
        store: store,
        device: fixture.device,
        seed: fixture.seed,
        keys: fixture.keys);
    expect(replica.rejected.containsKey(bad.id), isTrue);
    expect(replica.service.state.messages, isEmpty);
    await expectLater(
        replica.execute(
            actorId: fixture.botId,
            operation: 'message.send',
            params: parameters('仍不能发'),
            conversation: 'public#main'),
        throwsA(anything));
    expect(store.allEnvelopes.length, 1);
    await replica.close();
    await store.close();
  });
}

Map<String, dynamic> parameters(String text) => {
      'conversation': 'public#main',
      'parts': [
        {
          'type': 'text',
          'data': {'text': text}
        }
      ]
    };
Map<String, dynamic> command(String actor, String text) => {
      'version': 1,
      'actor': actor,
      'operation': 'message.send',
      'params': parameters(text)
    };
Future<void> prime(FileEventStore store, Fixture f) async {
  await store.append(device: f.device, key: f.keys.first, body: {
    'version': 1,
    'actor': f.identity.public.accountId,
    'operation': 'key.rotate',
    'params': {'announcement': f.announcement.toJson()}
  });
  for (final grant in f.grants)
    await store.append(device: f.device, key: f.keys.first, body: {
      'version': 1,
      'actor': f.identity.public.accountId,
      'operation': 'key.grant',
      'params': {'grant': grant.toJson()}
    });
}

Future<Fixture> build() async {
  final identity = await Identity.create('alice');
  final other = await Identity.create('bob');
  final device = await DeviceCredentials.create();
  await device.authorize(identity, 'community');
  final trust = TrustStore('community')
    ..trustAccount(identity.public)
    ..trustAccount(other.public);
  await trust.authorizeDevice(device.certificate!);
  final seed = ChatState(communityOwnerId: identity.public.accountId);
  final service = ChatService(seed);
  service.registerAccount(
      id: identity.public.accountId, name: 'alice', displayName: '爱丽丝');
  service.registerAccount(
      id: other.public.accountId, name: 'bob', displayName: '鲍勃');
  const botId = 'alice_bot';
  service.registerBot(
      actor: service.actor(identity.public.accountId),
      id: botId,
      displayName: '小在');
  service.createSpace(
      actor: service.actor(identity.public.accountId),
      id: 'public',
      title: '在座频道',
      publicChannel: true);
  service.joinSpace(
      actor: service.actor(identity.public.accountId),
      spaceId: 'public',
      botId: botId);
  service.joinSpace(
      actor: service.actor(other.public.accountId), spaceId: 'public');
  final manager = ConversationKeyManager(
      service: service,
      communityId: 'community',
      trustedAccounts: trust.accounts);
  final rotation =
      await manager.generate(sender: identity, conversationId: 'public#main');
  final grants = <KeyGrant>[];
  for (final principal in manager
      .resolveAuthorizedRecipients('public#main')
      .principalOwnerIds
      .keys)
    grants.add(await manager.issue(
        sender: identity,
        key: rotation.key,
        announcement: rotation.announcement,
        recipientPrincipalId: principal));
  await service.close();
  return (
    identity: identity,
    other: other,
    device: device,
    trust: trust,
    seed: seed,
    keys: [ConversationKey.generate('control:community', 1), rotation.key],
    announcement: rotation.announcement,
    grants: grants,
    botId: botId
  );
}
