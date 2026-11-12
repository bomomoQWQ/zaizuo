import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';
import 'package:zaizuo_relay/zaizuo_relay.dart';
import 'package:zaizuo_runtime/zaizuo_runtime.dart';

const _password = 'T9!Q2#LocalOnly7@';
const _fast = KdfParameters(memoryKiB: 32, iterations: 1, parallelism: 1);
const _token = 'local-node-onebot-token-0123456789abcdef';
const _relayToken = 'local-node-relay-token-0123456789abcdef';

void main() {
  test(
      'local draft stays private, creates no envelope and survives profile reopen',
      () async {
    final fixture = await _NodeFixture.create();
    addTearDown(fixture.dispose);
    final node = await fixture.node(fixture.alice);
    final before = node.store.allEnvelopes.length;
    final result = await node.execute(
        operation: 'bot.draft',
        params: {'id': 'private-draft', 'display_name': 'Private Draft'});
    expect(result['local_only'], isTrue);
    expect(result.containsKey('event_id'), isFalse);
    expect((result['result'] as Map)['draft'], isTrue);
    expect(node.store.allEnvelopes.length, before);
    expect(
        node.replica.service.state.bots.containsKey('private-draft'), isFalse);
    await node.close();
    final reopened = await LocalProfile.open(fixture.alice.root, _password);
    expect(reopened.localDrafts['private-draft']!.displayName, 'Private Draft');
    expect(reopened.localDrafts['private-draft']!.active, isFalse);
    expect(await reopened.file('local-private.json').readAsString(),
        isNot(contains('Private Draft')));
    final restored = await fixture.node(reopened);
    expect(restored.store.allEnvelopes.length, before);
    expect(restored.replica.service.state.bots.containsKey('private-draft'),
        isFalse);
  });

  test(
      'local draft rejects unknown fields, active and local ID collisions without writing events',
      () async {
    final fixture = await _NodeFixture.create();
    addTearDown(fixture.dispose);
    final node = await fixture.node(fixture.alice);
    await node.execute(
        operation: 'bot.register',
        params: {'id': 'active-bot', 'display_name': 'Active'});
    await node.execute(
        operation: 'bot.draft',
        params: {'id': 'local-bot', 'display_name': 'Local'});
    final before = node.store.allEnvelopes.length;
    for (final params in [
      {'id': 'unexpected', 'display_name': 'No', 'actor': 'spoof'},
      {'id': 'active-bot', 'display_name': 'Collision'},
      {'id': 'local-bot', 'display_name': 'Duplicate'},
      {'id': '', 'display_name': 'Empty'},
    ]) {
      await expectLater(node.execute(operation: 'bot.draft', params: params),
          throwsA(isA<DomainException>()));
    }
    await expectLater(
        node.execute(
            actorId: 'active-bot',
            operation: 'bot.draft',
            params: {'id': 'spoofed', 'display_name': 'Spoofed'}),
        throwsA(isA<DomainException>()));
    expect(node.store.allEnvelopes.length, before);
    expect(fixture.alice.localDrafts.keys, ['local-bot']);
  });

  test(
      'draft admission obeys real quotas, preserves failures and only publishes bot.register',
      () async {
    final fixture = await _NodeFixture.create();
    addTearDown(fixture.dispose);
    final node = await fixture.node(fixture.alice);
    await node.execute(operation: 'community.configure', params: {
      'config': {'maxBotsPerOwner': 1}
    });
    await node.execute(
        operation: 'bot.register',
        params: {'id': 'quota-bot', 'display_name': 'Quota'});
    // Drafts are local and unlimited even when the community admission quota is full.
    for (var i = 0; i < 3; i++) {
      await node.execute(
          operation: 'bot.draft',
          params: {'id': 'draft-$i', 'display_name': 'Draft $i'});
    }
    final before = node.store.allEnvelopes.length;
    await expectLater(
        node.execute(operation: 'bot.admit', params: {'bot_id': 'draft-0'}),
        throwsA(isA<DomainException>()
            .having((e) => e.code, 'code', 'quota_exceeded')));
    expect(node.store.allEnvelopes.length, before);
    expect(fixture.alice.localDrafts.containsKey('draft-0'), isTrue);
    await node
        .execute(operation: 'bot.retire', params: {'bot_id': 'quota-bot'});
    final result = await node
        .execute(operation: 'bot.admit', params: {'bot_id': 'draft-0'});
    expect(result['event_id'], isA<String>());
    expect(fixture.alice.localDrafts.containsKey('draft-0'), isFalse);
    expect(fixture.alice.localDrafts.length, 2);
    expect(node.replica.service.state.bots['draft-0']!.active, isTrue);
    final control = node.replica.keys.singleWhere((key) =>
        key.conversationId == 'control:${fixture.alice.manifest.communityId}');
    final operations = <String>[];
    for (final event in node.store.allEnvelopes) {
      operations.add((await event.decrypt(control))['operation'] as String);
    }
    expect(operations, isNot(contains('bot.draft')));
    expect(operations.last, 'bot.register');
    await node.close();
    final reopened = await LocalProfile.open(fixture.alice.root, _password);
    expect(reopened.localDrafts.containsKey('draft-0'), isFalse);
    expect(reopened.localDrafts.length, 2);
  });

  test(
      'node routes commands, saves learned keys, fixed-bot social writes and ID map survive restart',
      () async {
    final fixture = await _NodeFixture.create();
    addTearDown(fixture.dispose);
    final node = await fixture.node(fixture.alice);
    expect(identical(node.store.trust, fixture.alice.trust), isTrue);
    await node.execute(
        operation: 'bot.register',
        params: {'id': 'nodebot', 'display_name': 'Node Bot'});
    await node.execute(operation: 'space.create', params: {
      'id': 'node-lobby',
      'title': 'Node Lobby',
      'public_channel': true,
    });
    await node.execute(
        operation: 'space.join',
        params: {'space': 'node-lobby', 'bot_id': 'nodebot'});
    await node.execute(operation: 'room.create', params: {
      'space': 'node-lobby',
      'id': 'node-forum',
      'title': 'Forum',
      'kind': 'forum',
    });
    await node.start(botId: 'nodebot', token: _token, port: 0);
    final sent = await _action(node.port!, 'send_message', {
      'detail_type': 'group',
      'group_id': 'node-lobby#main',
      'message': 'Node durable message',
    });
    expect(sent['retcode'], 0);
    final native = sent['data']['message_id'] as String;
    final mapped = node.ids!.encode('message', native);
    final diskIds = await fixture.alice.file('onebot-ids.json').readAsString();
    expect(diskIds, contains(native));
    final social = await _action(node.port!, 'zaizuo.post_forum', {
      'room_id': 'node-forum',
      'title': 'Durable post',
      'message': 'Persistent forum body',
    });
    expect(social['retcode'], 0, reason: '$social');
    expect(node.replica.service.state.forumPosts, hasLength(1));
    expect(node.store.allEnvelopes.where((e) => e.conversation == 'node-forum'),
        isNotEmpty);
    expect(await node.store.logFile.readAsString(),
        isNot(contains('Persistent forum body')));
    final forbidden = await _action(node.port!, 'send_message', {
      'detail_type': 'group',
      'group_id': 'node-lobby#main',
      'message': 'wrong identity',
    }, self: {
      'platform': 'zaizuo',
      'user_id': fixture.alice.identity.public.accountId
    });
    expect(forbidden['retcode'], isNot(0));
    await node.close();
    final reopenedProfile =
        await LocalProfile.open(fixture.alice.root, _password);
    expect(reopenedProfile.keys.any((k) => k.conversationId == 'node-forum'),
        isTrue);
    final reopened = await fixture.node(reopenedProfile);
    await reopened.start(botId: 'nodebot', token: _token, port: 0);
    expect(reopened.ids!.decode('message', mapped), native);
    expect(reopened.replica.service.state.messages.containsKey(native), isTrue);
    expect(reopened.replica.service.state.forumPosts, hasLength(1));
    expect(reopened.replica.rejected, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
      'manifest history admits another account before Git events and repeated sync does not duplicate',
      () async {
    final fixture = await _NodeFixture.create(withGit: true);
    addTearDown(fixture.dispose);
    final a = await fixture.node(fixture.alice,
        git: await fixture.gitFor(fixture.alice, 'a-clone'));
    await a.syncOnce();
    final bob = await fixture.joiner();
    final b =
        await fixture.node(bob, git: await fixture.gitFor(bob, 'b-clone'));
    final next = await a.admit(await bob.joinRequest());
    expect(next.revision, 2);
    await a.execute(operation: 'space.create', params: {
      'id': 'git-node-lobby',
      'title': 'Git Node Lobby',
      'public_channel': true,
    });
    await a.syncOnce();
    await b.syncOnce();
    expect(b.profile.manifest.revision, 2);
    expect(
        b.replica.service.state.accounts
            .containsKey(bob.identity.public.accountId),
        isTrue);
    expect(
        b.store.trust.devices.containsKey(bob.device.certificate!.id), isTrue);
    expect(identical(b.store.trust, bob.trust), isTrue);
    await b
        .execute(operation: 'space.join', params: {'space': 'git-node-lobby'});
    await b.syncOnce();
    await a.syncOnce();
    final count = a.store.allEnvelopes.length;
    final first = a.syncOnce();
    final second = a.syncOnce();
    expect(identical(first, second), isTrue);
    await Future.wait([first, second]);
    expect(a.store.allEnvelopes.length, count);
    expect(a.replica.rejected, isEmpty);
    expect(b.replica.rejected, isEmpty);
    // A new installation may receive only the latest external manifest, not
    // its older revisions. Verified main must supplement that suffix before
    // historical events are replayed under manifest-account epoch context.
    final lateDirectory = Directory(p.join(fixture.root.path, 'charlie'));
    await LocalProfile.initialize(lateDirectory,
        name: 'charlie',
        displayName: 'Charlie',
        password: _password,
        community: a.profile.manifest,
        pinnedFingerprint: await a.profile.manifest.fingerprint(),
        parameters: _fast);
    final lateProfile = await LocalProfile.open(lateDirectory, _password);
    expect(lateProfile.manifestHistory.map((m) => m.revision), [2]);
    await a.admit(await lateProfile.joinRequest());
    await a.syncOnce();
    final lateNode = await fixture.node(lateProfile,
        git: await fixture.gitFor(lateProfile, 'late-clone'));
    await lateNode.syncOnce();
    expect(lateProfile.manifestHistory.map((m) => m.revision), [1, 2, 3]);
    expect(lateNode.profile.manifest.revision, 3);
    expect(lateNode.replica.rejected, isEmpty);
    expect(lateNode.replica.service.state.spaces.containsKey('git-node-lobby'),
        isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('serve background Git runs without relay and shutdown stops timer',
      () async {
    final fixture = await _NodeFixture.create(withGit: true);
    addTearDown(fixture.dispose);
    final node = await fixture.node(fixture.alice,
        git: await fixture.gitFor(fixture.alice, 'background-clone'),
        interval: const Duration(seconds: 1));
    await node.execute(
        operation: 'bot.register',
        params: {'id': 'backgroundbot', 'display_name': 'Background'});
    await node.start(botId: 'backgroundbot', token: _token, port: 0);
    await _eventually(
        () => node.completedSyncs >= 2, const Duration(seconds: 30));
    expect(node.relayConnected, isFalse);
    final rounds = node.completedSyncs;
    await node.close();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(node.completedSyncs, rounds);
    expect(node.isClosed, isTrue);
    await expectLater(node.syncOnce(), throwsStateError);
    final reopened = await LocalProfile.open(fixture.alice.root, _password);
    final next = await fixture.node(reopened);
    expect(
        next.replica.service.state.bots.containsKey('backgroundbot'), isTrue);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test(
      'relay accelerates already-flushed events and loss does not stop periodic Git',
      () async {
    final relay = await RelayServer.start(RelayConfig(token: _relayToken));
    addTearDown(relay.close);
    final fixture = await _NodeFixture.create(withGit: true);
    addTearDown(fixture.dispose);
    final a = await fixture.node(fixture.alice,
        git: await fixture.gitFor(fixture.alice, 'relay-a'),
        interval: const Duration(seconds: 1),
        relay: Uri.parse('ws://127.0.0.1:${relay.port}/v1/ws'));
    final bob = await fixture.joiner();
    await a.admit(await bob.joinRequest());
    await a.syncOnce();
    final b = await fixture.node(bob,
        git: await fixture.gitFor(bob, 'relay-b'),
        interval: const Duration(seconds: 1),
        relay: Uri.parse('ws://127.0.0.1:${relay.port}/v1/ws'));
    await b.syncOnce();
    await a.execute(
        operation: 'bot.register',
        params: {'id': 'relaybot', 'display_name': 'Relay'});
    await b.execute(
        operation: 'bot.register',
        params: {'id': 'receiverbot', 'display_name': 'Receiver'});
    await a.start(botId: 'relaybot', token: _token, port: 0);
    await b.start(botId: 'receiverbot', token: _token, port: 0);
    await _eventually(() => a.relayConnected && b.relayConnected,
        const Duration(seconds: 20));
    final before = b.store.allEnvelopes.length;
    final result = await a.execute(operation: 'space.create', params: {
      'id': 'relayed-lobby',
      'title': 'Relayed',
      'public_channel': true,
    });
    final eventId = result['event_id'];
    await _eventually(() => b.store.allEnvelopes.any((e) => e.id == eventId),
        const Duration(seconds: 20));
    expect(b.store.allEnvelopes.length, greaterThan(before));
    expect(await b.store.logFile.readAsString(), contains(eventId));
    final rounds = a.completedSyncs;
    await relay.close();
    await _eventually(
        () => a.completedSyncs > rounds, const Duration(seconds: 25));
    expect(a.lastSyncError, isNull);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
      'reject public relay and intervals below one second before opening store',
      () async {
    final fixture = await _NodeFixture.create();
    addTearDown(fixture.dispose);
    await expectLater(
        ZaizuoNode.open(
            profile: fixture.alice,
            syncInterval: const Duration(milliseconds: 500)),
        throwsArgumentError);
    await expectLater(
        ZaizuoNode.open(
            profile: fixture.alice,
            relayUrl: Uri.parse('ws://example.com:8787/v1/ws'),
            relayToken: _relayToken),
        throwsA(isA<RelayLinkException>()));
    final node = await fixture.node(fixture.alice);
    await node.execute(
        operation: 'bot.register',
        params: {'id': 'ownbot', 'display_name': 'Own'});
    await expectLater(
        node.start(
            botId: fixture.alice.identity.public.accountId,
            token: _token,
            port: 0),
        throwsStateError);
  });

  test(
      'more than 64 hashed topics disables relay rather than silently dropping scopes',
      () async {
    final fixture = await _NodeFixture.create();
    addTearDown(fixture.dispose);
    final node = await fixture.node(fixture.alice,
        relay: Uri.parse('ws://127.0.0.1:1/v1/ws'));
    for (var i = 0; i < 64; i++) {
      await node.store.append(
          device: fixture.alice.device,
          key: ConversationKey.generate('unknown-scope-$i', 1),
          body: {'opaque': true});
    }
    // Unknown encrypted scopes cannot be decrypted or rotate keys, but their
    // topics count toward the transport cap; no subscription is silently lost.
    await node.syncOnce();
    expect(node.relayConnected, isFalse);
    expect(node.lastRelayError, 'too_many_topics');
    expect(node.completedSyncs, 1);
  });
}

class _NodeFixture {
  final Directory root;
  final Directory? bare;
  final LocalProfile alice;
  final nodes = <ZaizuoNode>[];
  final repositories = <GitSync>[];
  _NodeFixture(this.root, this.bare, this.alice);
  static Future<_NodeFixture> create({bool withGit = false}) async {
    final root = await Directory.systemTemp.createTemp('zaizuo-node-test-');
    final bare = withGit ? Directory(p.join(root.path, 'remote.git')) : null;
    if (bare != null) {
      final result = await Process.run('git', [
        'init',
        '--bare',
        '--initial-branch=main',
        '--template=',
        bare.path
      ]);
      if (result.exitCode != 0) throw StateError('local test git init failed');
    }
    final profileDir = Directory(p.join(root.path, 'alice'));
    await LocalProfile.initialize(profileDir,
        name: 'alice',
        displayName: 'Alice',
        password: _password,
        parameters: _fast);
    return _NodeFixture(
        root, bare, await LocalProfile.open(profileDir, _password));
  }

  Future<LocalProfile> joiner() async {
    final directory = Directory(p.join(root.path, 'bob'));
    await LocalProfile.initialize(directory,
        name: 'bob',
        displayName: 'Bob',
        password: _password,
        community: alice.manifest,
        pinnedFingerprint: await alice.manifest.fingerprint(),
        parameters: _fast);
    return LocalProfile.open(directory, _password);
  }

  Future<GitSync> gitFor(LocalProfile profile, String name) async {
    final git = await GitSync.initialize(
        worktree: Directory(p.join(root.path, name)),
        remoteUrl: bare!.path,
        deviceId: profile.device.certificate!.id);
    repositories.add(git);
    return git;
  }

  Future<ZaizuoNode> node(LocalProfile profile,
      {GitSync? git,
      Duration interval = const Duration(seconds: 30),
      Uri? relay}) async {
    final node = await ZaizuoNode.open(
        profile: profile,
        git: git,
        syncInterval: interval,
        relayUrl: relay,
        relayToken: relay == null ? null : _relayToken);
    nodes.add(node);
    return node;
  }

  Future<void> dispose() async {
    for (final node in nodes) {
      await node.close();
    }
    for (final git in repositories) {
      await git.close();
    }
    final absolute = p.normalize(p.absolute(root.path));
    if (p.isWithin(
            p.normalize(p.absolute(Directory.systemTemp.path)), absolute) &&
        p.basename(absolute).startsWith('zaizuo-node-test-')) {
      await root.delete(recursive: true);
    } else {
      throw StateError('refuse unexpected node test cleanup');
    }
  }
}

Future<Map<String, dynamic>> _action(
    int port, String action, Map<String, dynamic> params,
    {Map<String, dynamic>? self}) async {
  final client = HttpClient();
  try {
    final request =
        await client.postUrl(Uri.parse('http://127.0.0.1:$port/onebot/v12'));
    request.headers
      ..set('Authorization', 'Bearer $_token')
      ..contentType = ContentType.json;
    request.write(jsonEncode(
        {'action': action, 'params': params, if (self != null) 'self': self}));
    final response = await request.close().timeout(const Duration(seconds: 15));
    return jsonObject(await response.transform(utf8.decoder).join());
  } finally {
    client.close(force: true);
  }
}

Future<void> _eventually(bool Function() predicate, Duration timeout) async {
  final end = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(end))
      throw StateError('node condition timed out');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
