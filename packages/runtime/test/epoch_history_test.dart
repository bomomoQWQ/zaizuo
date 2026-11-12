// 真身份、原始密文日志和epoch重放集成回归，不替代密码学审计。
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';
import 'package:zaizuo_runtime/zaizuo_runtime.dart';

const _community = 'epoch-history-community';
const _space = 'epoch-space';
const _room = 'epoch-space#main';
const _control = 'control:$_community';

List<JsonMap> _text(String text) => [
      {
        'type': 'text',
        'data': {'text': text}
      },
    ];

class _Peer {
  _Peer(this.identity, this.device, this.store, this.replica);
  final Identity identity;
  final DeviceCredentials device;
  final FileEventStore store;
  final EncryptedReplica replica;
  String get id => identity.public.accountId;
}

class _Fixture {
  _Fixture(this.root, this.identities, this.devices, this.seed, this.control);
  final Directory root;
  final List<Identity> identities;
  final List<DeviceCredentials> devices;
  final ChatState seed;
  final ConversationKey control;
  late final _Peer alice;
  late final _Peer bob;
  late final _Peer carol;

  static Future<_Fixture> create({bool bobJoined = false}) async {
    final root = await Directory.systemTemp.createTemp('zaizuo-epoch-history-');
    // Cleanup is registered before any subsequent operation can throw. Peers
    // register store/replica cleanup later, so they close before root deletion.
    addTearDown(() => root.delete(recursive: true));
    final identities =
        await Future.wait(['alice', 'bob', 'carol'].map(Identity.create));
    final devices = <DeviceCredentials>[];
    for (final identity in identities) {
      final device = await DeviceCredentials.create();
      await device.authorize(identity, _community);
      devices.add(device);
    }
    final seed = ChatState(communityOwnerId: identities.first.public.accountId);
    var counter = 0;
    final builder = ChatService(seed,
        now: () => DateTime.utc(2026, 1, 1),
        idGenerator: (prefix) => '$prefix:epoch-seed:${counter++}');
    addTearDown(builder.close);
    for (final identity in identities) {
      builder.registerAccount(
          id: identity.public.accountId,
          name: identity.public.name,
          displayName: identity.public.name);
    }
    builder.createSpace(
        actor: builder.actor(identities.first.public.accountId),
        id: _space,
        title: 'epoch history test',
        publicChannel: true,
        config: SpaceConfig(historyVisibleToNewMembers: false));
    if (bobJoined) {
      builder.joinSpace(
          actor: builder.actor(identities[1].public.accountId),
          spaceId: _space);
    }
    await builder.close();
    final f = _Fixture(
        root, identities, devices, seed, ConversationKey.generate(_control, 1));
    f.alice = await f.peer(0, 'alice');
    f.bob = await f.peer(1, 'bob');
    f.carol = await f.peer(2, 'carol');
    return f;
  }

  Future<_Peer> peer(int index, String name,
      {ChatState? state, Iterable<ConversationKey>? keys}) async {
    final trust = TrustStore(_community);
    for (final identity in identities) trust.trustAccount(identity.public);
    for (final device in devices)
      await trust.authorizeDevice(device.certificate!);
    final store =
        await FileEventStore.open(Directory('${root.path}/$name'), trust);
    addTearDown(store.close);
    final replica = await EncryptedReplica.open(
        store: store,
        device: devices[index],
        identity: identities[index],
        seed: state ?? seed,
        keys: keys ?? [control]);
    addTearDown(replica.close);
    return _Peer(identities[index], devices[index], store, replica);
  }

  Future<void> copy(_Peer from, _Peer to, {bool refresh = true}) async {
    // Includes every signed opaque device-chain predecessor, not just a topic.
    for (final envelope in from.store.allEnvelopes) {
      await to.store.import(EncryptedEvent.fromJson(
          jsonObject(canonicalJson(envelope.toJson()))));
    }
    if (refresh) await to.replica.refresh();
  }

  Future<EncryptedEvent> send(_Peer peer, String text) async {
    final result = await peer.replica.execute(
        actorId: peer.id,
        operation: 'message.send',
        params: {'conversation': _room, 'parts': _text(text)},
        conversation: _room);
    return peer.store.allEnvelopes
        .singleWhere((event) => event.id == result['event_id']);
  }

  Future<List<EncryptedEvent>> operations(_Peer peer, String operation) async {
    final events = <EncryptedEvent>[];
    for (final event in peer.store.allEnvelopes
        .where((event) => event.conversation == _control)) {
      final body = await event.decrypt(control);
      if (body['operation'] == operation) events.add(event);
    }
    return events;
  }

  ConversationKey key(_Peer peer, int epoch) => peer.replica.keys
      .singleWhere((key) => key.conversationId == _room && key.epoch == epoch);
}

void main() {
  test('根名册additive新增账号后旧public/private feed仍按历史授权重放', () async {
    const tiny = KdfParameters(memoryKiB: 32, iterations: 1, parallelism: 1);
    const password = 'R7!mK2@wX9#vT4%p';
    final root =
        await Directory.systemTemp.createTemp('zaizuo-epoch-manifest-');
    addTearDown(() => root.delete(recursive: true));
    final aliceDirectory = Directory('${root.path}/alice');
    await LocalProfile.initialize(aliceDirectory,
        name: 'alice',
        displayName: 'Alice',
        password: password,
        parameters: tiny);
    var alice = await LocalProfile.open(aliceDirectory, password);
    final bobDirectory = Directory('${root.path}/bob');
    await LocalProfile.initialize(bobDirectory,
        name: 'bob',
        displayName: 'Bob',
        password: password,
        parameters: tiny,
        community: alice.manifest,
        pinnedFingerprint: await alice.manifest.fingerprint());
    final bob = await LocalProfile.open(bobDirectory, password);
    final second = await alice.admit(await bob.joinRequest());
    await alice.acceptManifest(second);
    await bob.acceptManifest(second);
    final (oldStore, oldReplica) = await alice.replica();
    addTearDown(oldStore.close);
    addTearDown(oldReplica.close);
    Future<Map<String, dynamic>> post(
            EncryptedReplica replica, String visibility, String message) =>
        replica.execute(
            actorId: alice.identity.public.accountId,
            operation: 'feed.post',
            params: {'visibility': visibility, 'parts': _text(message)},
            conversation:
                'feed:${alice.identity.public.accountId}:$visibility');
    final oldPublic =
        await post(oldReplica, 'public', 'public-at-root-revision-2');
    final oldPrivate =
        await post(oldReplica, 'private', 'private-at-root-revision-2');
    final publicScope = 'feed:${alice.identity.public.accountId}:public';
    final oldPublicEnvelope = oldStore.allEnvelopes
        .singleWhere((event) => event.id == oldPublic['event_id']);
    expect(oldPublicEnvelope.epoch, 1);
    expect(oldReplica.service.state.feedPosts, hasLength(2));
    alice.keys
      ..clear()
      ..addAll(oldReplica.keys);
    await alice.savePrivate(seed: alice.seed, keys: alice.keys);
    await oldReplica.close();
    await oldStore.close();

    final carolDirectory = Directory('${root.path}/carol');
    await LocalProfile.initialize(carolDirectory,
        name: 'carol',
        displayName: 'Carol',
        password: password,
        parameters: tiny,
        community: alice.manifest,
        pinnedFingerprint: await alice.manifest.fingerprint());
    var carol = await LocalProfile.open(carolDirectory, password);
    final third = await alice.admit(await carol.joinRequest());
    expect(third.revision, 3);
    await alice.acceptManifest(third);
    await bob.acceptManifest(third);
    await carol.acceptManifest(third);
    // Reopen from actual signed/encrypted local profile and old event log;
    // state.enc is not read and no prior projected service is reused.
    alice = await LocalProfile.open(aliceDirectory, password);
    final (store, replica) = await alice.replica();
    addTearDown(store.close);
    addTearDown(replica.close);
    expect(replica.rejected, isEmpty,
        reason: 'root additive roster must not rewrite historical audience');
    expect(replica.service.state.feedPosts.keys.toSet(), {
      (oldPublic['result'] as Map)['id'],
      (oldPrivate['result'] as Map)['id'],
    });
    final fresh = await post(replica, 'public', 'public-at-root-revision-3');
    final freshEnvelope = store.allEnvelopes
        .singleWhere((event) => event.id == fresh['event_id']);
    expect(freshEnvelope.epoch, 2);
    carol = await LocalProfile.open(carolDirectory, password);
    final (carolStore, carolReplica) = await carol.replica();
    addTearDown(carolStore.close);
    addTearDown(carolReplica.close);
    for (final event in store.allEnvelopes) {
      await carolStore.import(
          EncryptedEvent.fromJson(jsonObject(canonicalJson(event.toJson()))));
    }
    await carolReplica.refresh();
    final newPublicKey = carolReplica.keys
        .singleWhere((key) => key.conversationId == publicScope);
    expect(newPublicKey.epoch, 2);
    expect(
        carolReplica.keys.any((key) => key.conversationId.endsWith(':private')),
        isFalse);
    await expectLater(
        oldPublicEnvelope.decrypt(ConversationKey(
            conversationId: publicScope, epoch: 1, bytes: newPublicKey.bytes)),
        throwsA(isA<SecretBoxAuthenticationError>()));
    expect(
        (await freshEnvelope.decrypt(newPublicKey))['operation'], 'feed.post');
    expect(carolReplica.service.state.feedPosts.keys,
        [(fresh['result'] as Map)['id']]);
  });

  test('同Replica并发ensure同scope只发布一个epoch且接收方无分叉', () async {
    final f = await _Fixture.create(bobJoined: true);
    await Future.wait(
        List.generate(8, (_) => f.alice.replica.ensureConversationKey(_room)));
    final rotations = await f.operations(f.alice, 'key.rotate');
    expect(rotations, hasLength(1));
    final body = await rotations.single.decrypt(f.control);
    expect(
        (((body['params'] as Map)['announcement'] as Map)['body']
            as Map)['epoch'],
        1);
    expect(f.alice.replica.keys.where((key) => key.conversationId == _room),
        hasLength(1));
    await f.copy(f.alice, f.bob);
    expect(f.key(f.bob, 1).bytes, f.key(f.alice, 1).bytes);
    expect(f.bob.replica.rejected, isEmpty);
    final event = await f.send(f.alice, 'after-concurrent-ensure');
    await f.copy(f.alice, f.bob);
    expect((await event.decrypt(f.key(f.bob, 1)))['params'],
        containsPair('conversation', _room));
  });

  test('新人仅领加入后epoch2，不能解epoch1旧正文但能解新消息', () async {
    final f = await _Fixture.create();
    final old = await f.send(f.alice, 'old-before-bob-joined');
    expect(old.epoch, 1);
    await f.copy(f.alice, f.bob);
    expect(f.bob.replica.keys.where((key) => key.conversationId == _room),
        isEmpty);
    await f.bob.replica.execute(
        actorId: f.bob.id,
        operation: 'space.join',
        params: {'space': _space},
        conversation: _control);
    await f.copy(f.bob, f.alice);
    await f.alice.replica.ensureConversationKey(_room);
    final fresh = await f.send(f.alice, 'new-after-bob-joined');
    expect(fresh.epoch, 2);
    await f.copy(f.alice, f.bob);
    final bobKey = f.key(f.bob, 2);
    expect(
        f.bob.replica.keys
            .where((key) => key.conversationId == _room)
            .map((key) => key.epoch),
        [2]);
    expect(bobKey.bytes, isNot(f.key(f.alice, 1).bytes));
    // Re-labeling the new secret as epoch1 must still fail AES-GCM; the test
    // does not rely only on the public method's epoch mismatch guard.
    final fakeOld =
        ConversationKey(conversationId: _room, epoch: 1, bytes: bobKey.bytes);
    await expectLater(
        old.decrypt(fakeOld), throwsA(isA<SecretBoxAuthenticationError>()));
    expect(
        (((await fresh.decrypt(bobKey))['params'] as Map)['parts'] as List)
            .single['data']['text'],
        'new-after-bob-joined');
    expect(
        f.bob.replica.service
            .messages(
                actor: f.bob.replica.service.actor(f.bob.id),
                conversationId: _room)
            .map((message) => message.parts.single['data']['text']),
        ['new-after-bob-joined']);
  });

  test('成员leave后旧历史仍可解，独立新epoch对退群人AES-GCM失败', () async {
    final f = await _Fixture.create(bobJoined: true);
    final old = await f.send(f.alice, 'history-readable-after-leave');
    await f.copy(f.alice, f.bob);
    final priorKey = f.key(f.bob, 1);
    expect(await old.decrypt(priorKey), isA<Map<String, dynamic>>());
    await f.bob.replica.execute(
        actorId: f.bob.id,
        operation: 'space.leave',
        params: {'space': _space},
        conversation: _control);
    await f.copy(f.bob, f.alice);
    await f.alice.replica.ensureConversationKey(_room);
    final fresh = await f.send(f.alice, 'new-after-bob-left');
    expect(fresh.epoch, 2);
    await f.copy(f.alice, f.bob);
    expect(
        f.bob.replica.keys
            .where((key) => key.conversationId == _room)
            .map((key) => key.epoch),
        [1]);
    expect(
        (((await old.decrypt(priorKey))['params'] as Map)['parts'] as List)
            .single['data']['text'],
        'history-readable-after-leave');
    final fakeFresh =
        ConversationKey(conversationId: _room, epoch: 2, bytes: priorKey.bytes);
    await expectLater(
        fresh.decrypt(fakeFresh), throwsA(isA<SecretBoxAuthenticationError>()));
    expect(
        f.bob.replica.service
            .messages(
                actor: f.bob.replica.service.actor(f.bob.id),
                conversationId: _room)
            .map((message) => message.parts.single['data']['text']),
        ['history-readable-after-leave']);
  });

  test('晚到recipient grant单次refresh就补重放前面已验签合法content', () async {
    final f = await _Fixture.create(bobJoined: true);
    final managerService = ChatService(ChatState.fromJson(f.seed.toJson()));
    addTearDown(managerService.close);
    final manager = ConversationKeyManager(
        service: managerService,
        communityId: _community,
        trustedAccounts: f.alice.store.trust.accounts);
    final rotation =
        await manager.generate(sender: f.alice.identity, conversationId: _room);
    final grant = await manager.issue(
        sender: f.alice.identity,
        key: rotation.key,
        announcement: rotation.announcement,
        recipientPrincipalId: f.bob.id);
    Future<EncryptedEvent> append(
            ConversationKey key, String operation, JsonMap params) =>
        f.alice.store.append(device: f.alice.device, key: key, body: {
          'version': 1,
          'actor': f.alice.id,
          'operation': operation,
          'params': params,
        });
    await append(f.control, 'key.rotate',
        {'announcement': rotation.announcement.toJson()});
    final content = await append(rotation.key, 'message.send', {
      'conversation': _room,
      'parts': _text('content-before-recipient-grant')
    });
    await f.copy(f.alice, f.bob);
    expect(f.bob.replica.service.state.messages, isEmpty);
    expect(f.bob.replica.keys.where((key) => key.conversationId == _room),
        isEmpty);
    final late =
        await append(f.control, 'key.grant', {'grant': grant.toJson()});
    await f.bob.store.import(late);
    // Exactly one public refresh; it must internally redo the earlier content
    // after obtaining its key later in sorted event order.
    await f.bob.replica.refresh();
    expect(f.bob.replica.rejected, isEmpty);
    expect(
        (await content.decrypt(f.key(f.bob, 1)))['operation'], 'message.send');
    expect(
        f.bob.replica.service
            .messages(
                actor: f.bob.replica.service.actor(f.bob.id),
                conversationId: _room)
            .single
            .parts
            .single['data']['text'],
        'content-before-recipient-grant');
  });
}
