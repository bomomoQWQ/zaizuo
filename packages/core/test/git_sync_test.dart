import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:zaizuo_core/src/codec.dart';
import 'package:zaizuo_core/src/crypto.dart';
import 'package:zaizuo_core/src/devices.dart';
import 'package:zaizuo_core/src/events.dart';
import 'package:zaizuo_core/src/git_sync.dart';
import 'package:zaizuo_core/src/git_cli_backend.dart';
import 'package:zaizuo_core/src/store.dart';

const _community = 'git-sync-integration-community';

void main() {
  late _Fixture fixture;
  setUp(() async {
    fixture = await _Fixture.create();
  });
  tearDown(() async {
    await fixture.dispose();
  });

  test(
      'real bare remote: multiple clones exchange original envelopes idempotently',
      () async {
    for (var i = 0; i < 5; i++) {
      await fixture.a.append(
          device: fixture.deviceA,
          key: fixture.key,
          body: {'message': '中文消息 $i'});
    }
    expect(await fixture.syncA.push(fixture.a), 5);
    expect(await fixture.syncA.push(fixture.a), 0);
    final aHead = await fixture.remoteHead(fixture.idA);
    expect(await fixture.syncB.pull(fixture.b), 5);
    expect(await fixture.syncB.pull(fixture.b), 0);
    expect(fixture.b.allEnvelopes.map((e) => e.toJson()),
        fixture.a.allEnvelopes.map((e) => e.toJson()));
    expect(await fixture.b.allEnvelopes.first.decrypt(fixture.key),
        {'message': '中文消息 0'});

    final reply = await fixture.b.append(
        device: fixture.deviceB,
        key: fixture.key,
        body: {'message': '来自第二台设备'});
    expect(await fixture.syncB.push(fixture.b), 1);
    expect(await fixture.remoteHead(fixture.idA), aHead,
        reason: 'receiving device must never rewrite the source branch');
    expect(await fixture.syncA.pull(fixture.a), 1);
    expect(await fixture.syncA.pull(fixture.a), 0);
    expect(fixture.a.allEnvelopes.last.id, reply.id);
    final bPaths = await fixture.git([
      '--git-dir=${fixture.remote.path}',
      'ls-tree',
      '-r',
      '--name-only',
      'refs/heads/dev/${fixture.idB}'
    ]);
    expect(bPaths.trim().split('\n'), ['logs/${fixture.idB}/00000000.jsonl']);
    final bText = await fixture.git([
      '--git-dir=${fixture.remote.path}',
      'show',
      'refs/heads/dev/${fixture.idB}:logs/${fixture.idB}/00000000.jsonl'
    ]);
    expect(const LineSplitter().convert(bText).length, 1);
    expect(EncryptedEvent.fromJson(jsonObject(bText.trim())).id, reply.id);

    final tracked = await fixture.git([
      '--git-dir=${fixture.remote.path}',
      'ls-tree',
      '-r',
      '--name-only',
      'refs/heads/dev/${fixture.idA}'
    ]);
    expect(tracked.trim().split('\n').length, 3,
        reason: 'five events with segmentSize=2 become three JSONL files');
    expect(tracked, isNot(contains('pinned_refs')));
    expect(
        await Directory(p.join(fixture.syncB.worktree.path, 'logs')).exists(),
        isFalse,
        reason: 'remote trees are never checked out');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('injected typed CLI backend interoperates and reopens with default CLI',
      () async {
    await fixture.a.append(
        device: fixture.deviceA,
        key: fixture.key,
        body: {'message': 'typed backend'});
    final path = Directory(p.join(fixture.root.path, 'injected'));
    final injected = await GitSync.initializeWithBackend(
        backend: GitCliBackend(),
        worktree: path,
        remoteUrl: fixture.remote.path,
        deviceId: fixture.idA,
        segmentSize: 2);
    fixture.syncs.add(injected);
    expect(await injected.push(fixture.a), 1);
    expect(await fixture.syncB.pull(fixture.b), 1);
    await injected.close();
    final reopened = await GitSync.initialize(
        worktree: path,
        remoteUrl: fixture.remote.path,
        deviceId: fixture.idA,
        segmentSize: 2);
    fixture.syncs.add(reopened);
    expect(await reopened.push(fixture.a), 0);
    expect(await reopened.pull(fixture.a), 0);
  });

  test('injected backend cannot open before repository identity validation',
      () async {
    final backend = _ObservedCliBackend();
    await expectLater(
        GitSync.initializeWithBackend(
            backend: backend,
            worktree: fixture.syncA.worktree,
            remoteUrl: fixture.remote.path,
            deviceId: fixture.idB,
            segmentSize: 2),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'repository_identity')));
    expect(backend.openCalls, 0);
    expect(backend.closeCalls, 1);
  });

  test('bad signature is rejected before import and pin advance', () async {
    final event = await fixture.a.append(
        device: fixture.deviceA,
        key: fixture.key,
        body: {'message': 'authentic'});
    final value = event.toJson()
      ..['signature'] = base64Encode(List<int>.filled(64, 0));
    await fixture.publishRaw(fixture.idA,
        {'logs/${fixture.idA}/00000000.jsonl': '${canonicalJson(value)}\n'});
    final pinsBefore = await fixture.pins(fixture.syncB);
    await expectLater(fixture.syncB.pull(fixture.b), throwsStateError);
    expect(fixture.b.allEnvelopes, isEmpty);
    expect(await fixture.pins(fixture.syncB), pinsBefore);
  });

  test('one invalid branch prevents partial acceptance of valid branches',
      () async {
    final valid = await fixture.a.append(
        device: fixture.deviceA, key: fixture.key, body: {'message': 'valid'});
    final invalid = await fixture.b.append(
        device: fixture.deviceB,
        key: fixture.key,
        body: {'message': 'invalid'});
    await fixture.syncA.push(fixture.a);
    final json = invalid.toJson()
      ..['signature'] = base64Encode(List<int>.filled(64, 0));
    await fixture.publishRaw(fixture.idB,
        {'logs/${fixture.idB}/00000000.jsonl': '${canonicalJson(json)}\n'});
    final thirdTrust = await fixture.trust();
    final third = await FileEventStore.open(
        Directory(p.join(fixture.root.path, 'third-store')), thirdTrust);
    final sync = await fixture.newSync('third-clone', fixture.idA);
    fixture.stores.add(third);
    fixture.syncs.add(sync);
    await expectLater(sync.pull(third), throwsStateError);
    expect(third.allEnvelopes, isEmpty);
    expect(valid.id, isNot(invalid.id));
  });

  test('valid signature cannot claim a different branch device', () async {
    final event = await fixture.a.append(
        device: fixture.deviceA,
        key: fixture.key,
        body: {'message': 'wrong branch'});
    await fixture.publishRaw(fixture.idB, {
      'logs/${fixture.idB}/00000000.jsonl': '${canonicalJson(event.toJson())}\n'
    });
    await expectLater(
        fixture.syncB.pull(fixture.b),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'origin_mismatch')));
    expect(fixture.b.allEnvelopes, isEmpty);
  });

  test(
      'first-seen branch cannot fork a device chain already in the local store',
      () async {
    final local = await fixture.a.append(
        device: fixture.deviceA,
        key: fixture.key,
        body: {'message': 'locally witnessed'});
    await fixture.b.import(local);
    final fork = await EncryptedEvent.create(
        communityId: _community,
        device: fixture.deviceA,
        key: fixture.key,
        sequence: 1,
        clock: 1,
        previous: null,
        body: {'message': 'alternate signed history'});
    await fixture.publishRaw(fixture.idA, {
      'logs/${fixture.idA}/00000000.jsonl': '${canonicalJson(fork.toJson())}\n',
    });
    final pinsBefore = await fixture.pins(fixture.syncB);
    await expectLater(fixture.syncB.pull(fixture.b), throwsStateError);
    expect(fixture.b.allEnvelopes.map((e) => e.id), [local.id]);
    expect(await fixture.pins(fixture.syncB), pinsBefore);
  });

  test('valid signed event chain gaps are refused', () async {
    final first = await fixture.a.append(
        device: fixture.deviceA, key: fixture.key, body: {'message': 'first'});
    final third = await EncryptedEvent.create(
        communityId: _community,
        device: fixture.deviceA,
        key: fixture.key,
        sequence: 3,
        clock: 3,
        previous: first.id,
        body: {'message': 'gap'});
    await fixture.publishRaw(fixture.idA, {
      'logs/${fixture.idA}/00000000.jsonl':
          '${canonicalJson(first.toJson())}\n${canonicalJson(third.toJson())}\n'
    });
    await expectLater(
        fixture.syncB.pull(fixture.b),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'invalid_chain')));
    expect(fixture.b.allEnvelopes, isEmpty);
  });

  test('force-push rollback is rejected after reopen, with pin unchanged',
      () async {
    await fixture.a.append(
        device: fixture.deviceA, key: fixture.key, body: {'message': 'one'});
    await fixture.syncA.push(fixture.a);
    final oldHead = await fixture.remoteHead(fixture.idA);
    await fixture.a.append(
        device: fixture.deviceA, key: fixture.key, body: {'message': 'two'});
    await fixture.syncA.push(fixture.a);
    expect(await fixture.syncB.pull(fixture.b), 2);
    final pinsBefore = await fixture.pins(fixture.syncB);
    await fixture.syncB.close();
    fixture.syncB = await fixture.newSync('clone B 中文', fixture.idB);
    fixture.syncs.add(fixture.syncB);
    await fixture.git([
      '-C',
      fixture.syncA.worktree.path,
      'push',
      '--force',
      '--',
      fixture.remote.path,
      '$oldHead:refs/heads/dev/${fixture.idA}'
    ]);
    await expectLater(
        fixture.syncB.pull(fixture.b),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'remote_rewrite')));
    expect(fixture.b.allEnvelopes.length, 2);
    expect(await fixture.pins(fixture.syncB), pinsBefore);
  });

  test('force-push unrelated fork is rejected', () async {
    final event = await fixture.a.append(
        device: fixture.deviceA, key: fixture.key, body: {'message': 'one'});
    await fixture.syncA.push(fixture.a);
    await fixture.syncB.pull(fixture.b);
    final pinsBefore = await fixture.pins(fixture.syncB);
    // Exactly the same signed content, but in an unrelated Git root commit.
    await fixture.publishRaw(
        fixture.idA,
        {
          'logs/${fixture.idA}/00000000.jsonl':
              '${canonicalJson(event.toJson())}\n'
        },
        message: 'unrelated fork');
    await expectLater(
        fixture.syncB.pull(fixture.b),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'remote_rewrite')));
    expect(await fixture.pins(fixture.syncB), pinsBefore);
  });

  test('descendant commit still cannot delete previously pinned events',
      () async {
    final first = await fixture.a.append(
        device: fixture.deviceA, key: fixture.key, body: {'message': 'one'});
    await fixture.a.append(
        device: fixture.deviceA, key: fixture.key, body: {'message': 'two'});
    await fixture.syncA.push(fixture.a);
    await fixture.syncB.pull(fixture.b);
    final parent = await fixture.remoteHead(fixture.idA);
    await fixture.publishRaw(
        fixture.idA,
        {
          'logs/${fixture.idA}/00000000.jsonl':
              '${canonicalJson(first.toJson())}\n'
        },
        parent: parent);
    await expectLater(
        fixture.syncB.pull(fixture.b),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'archive_rewrite')));
    expect(fixture.b.allEnvelopes.length, 2);
  });

  test('deleted pinned branch is reported instead of silently forgotten',
      () async {
    await fixture.a.append(
        device: fixture.deviceA, key: fixture.key, body: {'message': 'one'});
    await fixture.syncA.push(fixture.a);
    await fixture.syncB.pull(fixture.b);
    final pinsBefore = await fixture.pins(fixture.syncB);
    await fixture.git([
      '-C',
      fixture.syncA.worktree.path,
      'push',
      '--',
      fixture.remote.path,
      ':refs/heads/dev/${fixture.idA}'
    ]);
    await expectLater(
        fixture.syncB.pull(fixture.b),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'remote_deleted')));
    expect(await fixture.pins(fixture.syncB), pinsBefore);
  });

  test('parallel same-clone instances serialize pushes without lost update',
      () async {
    for (var i = 0; i < 3; i++) {
      await fixture.a.append(
          device: fixture.deviceA, key: fixture.key, body: {'message': '$i'});
    }
    final another = await fixture.newSync('clone A 中文', fixture.idA);
    fixture.syncs.add(another);
    final counts = await Future.wait([
      fixture.syncA.push(fixture.a),
      another.push(fixture.a),
      fixture.syncA.push(fixture.a),
      another.push(fixture.a),
    ]);
    expect(counts.fold<int>(0, (n, count) => n + count), 3);
    expect(await fixture.syncB.pull(fixture.b), 3);
    expect(fixture.b.allEnvelopes.length, 3);
    final count = await fixture.git([
      '--git-dir=${fixture.remote.path}',
      'rev-list',
      '--count',
      'refs/heads/dev/${fixture.idA}'
    ]);
    expect(count.trim(), '1');
  });

  test('an external process lock blocks synchronization until released',
      () async {
    await fixture.a.append(
        device: fixture.deviceA, key: fixture.key, body: {'message': 'one'});
    final clone = fixture.syncA.worktree.path;
    final lockPath =
        p.join(p.dirname(clone), '.${p.basename(clone)}.zaizuo-sync.lock');
    final script = File(p.join(fixture.root.path, 'lock-holder.dart'));
    await script.writeAsString('''
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  final lock = await File(args.single).open(mode: FileMode.append);
  await lock.lock(FileLock.blockingExclusive);
  stdout.writeln('locked');
  await stdin.transform(utf8.decoder).first;
  await lock.unlock();
  await lock.close();
}
''');
    final holder = await Process.start(
        Platform.resolvedExecutable, [script.path, lockPath],
        runInShell: false);
    try {
      expect(
          await holder.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first,
          'locked');
      var finished = false;
      final push = fixture.syncA.push(fixture.a).then((n) {
        finished = true;
        return n;
      });
      // Another isolate's timer remains live while native file-lock acquisition
      // is pending. This is observation, not a mocked Git implementation.
      await Isolate.run(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      expect(finished, isFalse);
      holder.stdin.writeln('release');
      await holder.stdin.flush();
      expect(await push, 1);
      expect(await holder.exitCode, 0);
    } finally {
      holder.kill();
      await holder.exitCode;
    }
  });

  test('remote tree cannot contain executables, symlinks or submodule entries',
      () async {
    final event = await fixture.a.append(
        device: fixture.deviceA, key: fixture.key, body: {'message': 'one'});
    for (final mode in ['100755', '120000']) {
      await fixture.publishRaw(
          fixture.idA,
          {
            'logs/${fixture.idA}/00000000.jsonl':
                '${canonicalJson(event.toJson())}\n'
          },
          fileMode: mode,
          message: 'forbidden mode $mode');
      await expectLater(
          fixture.syncB.pull(fixture.b),
          throwsA(isA<GitSyncException>()
              .having((e) => e.code, 'code', 'invalid_tree')));
    }
    final parent = await fixture.publishRaw(fixture.idA, {
      'logs/${fixture.idA}/00000000.jsonl':
          '${canonicalJson(event.toJson())}\n',
    });
    await fixture.publishRaw(
        fixture.idA,
        {
          'logs/${fixture.idA}/00000000.jsonl':
              '${canonicalJson(event.toJson())}\n',
        },
        parent: parent,
        gitlink: parent);
    await expectLater(
        fixture.syncB.pull(fixture.b),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'invalid_tree')));
    expect(fixture.b.allEnvelopes, isEmpty);
    expect(
        await Directory(p.join(fixture.syncB.worktree.path, 'logs')).exists(),
        isFalse);
  });

  test('remote hooks and attributes are not materialized or executed',
      () async {
    final event = await fixture.a.append(
        device: fixture.deviceA, key: fixture.key, body: {'message': 'one'});
    final marker = File(p.join(fixture.root.path, 'hook-ran'));
    // A local hook is unconditionally ignored by the controlled hooksPath.
    final hooks =
        Directory(p.join(fixture.syncA.worktree.path, '.git', 'hooks'));
    await hooks.create();
    final prePush = File(p.join(hooks.path, 'pre-push'));
    await prePush.writeAsString(
        '#!/bin/sh\necho bad > "${marker.path.replaceAll('\\', '/')}"\nexit 1\n');
    if (!Platform.isWindows) await Process.run('chmod', ['+x', prePush.path]);
    expect(await fixture.syncA.push(fixture.a), 1);
    expect(await marker.exists(), isFalse);
    final head = await fixture.remoteHead(fixture.idA);
    await fixture.publishRaw(
        fixture.idA,
        {
          'logs/${fixture.idA}/00000000.jsonl':
              '${canonicalJson(event.toJson())}\n',
          '.gitattributes': '* filter=evil\n',
          '.gitmodules': '[submodule "evil"]\n path=evil\n url=ext::evil\n',
        },
        parent: head);
    await expectLater(
        fixture.syncB.pull(fixture.b),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'invalid_tree')));
    expect(
        await File(p.join(fixture.syncB.worktree.path, '.gitmodules')).exists(),
        isFalse);
    expect(await marker.exists(), isFalse);
  });

  test('modified local automatic Git config and hooks directory fail closed',
      () async {
    await fixture.a.append(
        device: fixture.deviceA, key: fixture.key, body: {'message': 'one'});
    final config = File(p.join(fixture.syncA.worktree.path, '.git', 'config'));
    await config.writeAsString('[include]\n\tpath = unsafe\n',
        mode: FileMode.append);
    await expectLater(
        fixture.syncA.push(fixture.a),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'unsafe_configuration')));
    final hook = File(p.join(fixture.syncB.worktree.path, '.git', 'zaizuo-sync',
        'empty-hooks', 'pre-push'));
    await hook.writeAsString('exit 1');
    await expectLater(
        fixture.syncB.pull(fixture.b),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'unsafe_configuration')));
  });

  test(
      'local bare remote hooks and automatic config are rejected before execution',
      () async {
    await fixture.a.append(
        device: fixture.deviceA, key: fixture.key, body: {'message': 'one'});
    final marker = File(p.join(fixture.root.path, 'bare-hook-ran'));
    final hook = File(p.join(fixture.remote.path, 'hooks', 'pre-receive'));
    await hook.parent.create();
    await hook.writeAsString(
        '#!/bin/sh\necho bad > "${marker.path.replaceAll('\\', '/')}"\nexit 42\n');
    if (!Platform.isWindows) await Process.run('chmod', ['+x', hook.path]);
    await expectLater(
        fixture.syncA.push(fixture.a),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'unsafe_local_remote')));
    expect(await marker.exists(), isFalse);
    // The path was created immediately above inside the fixture's bare remote.
    await hook.delete();
    final config = File(p.join(fixture.remote.path, 'config'));
    await config.writeAsString('[include]\n path=untrusted\n',
        mode: FileMode.append);
    await expectLater(
        fixture.syncA.push(fixture.a),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'unsafe_local_remote')));
    expect(await marker.exists(), isFalse);
  });

  test('missing pin file never silently resets trust', () async {
    final pins = File(p.join(fixture.syncB.worktree.path, '.git', 'zaizuo-sync',
        'pinned_refs.json'));
    await pins.delete();
    await expectLater(
        fixture.syncB.pull(fixture.b),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'missing_pins')));
  });

  test(
      'unsafe URL schemes, embedded credentials and existing user repos are refused',
      () async {
    for (final url in [
      'ext::echo unsafe',
      'file:///tmp/repo',
      '../repo',
      'git@host:repo',
      'http://host/repo',
      'https://token@host/repo',
      'https://user:password@host/repo',
      'https://host/repo?token=secret',
      'ssh://git:password@host/repo',
      'ssh://git%3Asecret@host/repo',
      'ssh://-oProxyCommand=bad/repo',
      'https://host/../repo',
    ]) {
      await expectLater(
          GitSync.initialize(
            worktree: Directory(p.join(fixture.root.path, 'unsafe-url')),
            remoteUrl: url,
            deviceId: fixture.idA,
          ),
          throwsA(isA<GitSyncException>()
              .having((e) => e.code, 'code', 'invalid_remote')));
    }
    final userRepo = Directory(p.join(fixture.root.path, 'user-repo'));
    await fixture.git(['init', '--template=', userRepo.path]);
    await expectLater(
        GitSync.initialize(
            worktree: userRepo,
            remoteUrl: fixture.remote.path,
            deviceId: fixture.idA),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'unmanaged_repository')));
    final nonempty = Directory(p.join(fixture.root.path, 'nonempty'));
    await nonempty.create();
    await File(p.join(nonempty.path, 'keep.txt')).writeAsString('user data');
    await expectLater(
        GitSync.initialize(
            worktree: nonempty,
            remoteUrl: fixture.remote.path,
            deviceId: fixture.idA),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'unmanaged_repository')));
  });
}

class _ObservedCliBackend extends GitCliBackend {
  int openCalls = 0;
  int closeCalls = 0;
  @override
  Future<void> open(
      {required String worktreePath,
      required String remoteUrl,
      required bool create}) async {
    openCalls++;
    await super
        .open(worktreePath: worktreePath, remoteUrl: remoteUrl, create: create);
  }

  @override
  Future<void> close() async {
    closeCalls++;
    await super.close();
  }
}

class _Fixture {
  final Directory root;
  final Directory remote;
  final Identity identity;
  final DeviceCredentials deviceA;
  final DeviceCredentials deviceB;
  final String idA;
  final String idB;
  final ConversationKey key;
  late FileEventStore a;
  late FileEventStore b;
  late GitSync syncA;
  late GitSync syncB;
  final List<FileEventStore> stores = [];
  final List<GitSync> syncs = [];

  _Fixture(this.root, this.remote, this.identity, this.deviceA, this.deviceB,
      this.idA, this.idB, this.key);

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('zaizuo git 集成-');
    final remote = Directory(p.join(root.path, 'remote 裸.git'));
    final identity = await Identity.create('git_tester');
    final deviceA = await DeviceCredentials.create();
    final deviceB = await DeviceCredentials.create();
    await deviceA.authorize(identity, _community);
    await deviceB.authorize(identity, _community);
    final fixture = _Fixture(
        root,
        remote,
        identity,
        deviceA,
        deviceB,
        await deviceA.id,
        await deviceB.id,
        ConversationKey.generate('conversation', 1));
    await fixture.git(
        ['init', '--bare', '--template=', '--object-format=sha1', remote.path]);
    fixture.a = await FileEventStore.open(
        Directory(p.join(root.path, 'store A')), await fixture.trust());
    fixture.b = await FileEventStore.open(
        Directory(p.join(root.path, 'store B')), await fixture.trust());
    fixture.stores.addAll([fixture.a, fixture.b]);
    fixture.syncA = await fixture.newSync('clone A 中文', fixture.idA);
    fixture.syncB = await fixture.newSync('clone B 中文', fixture.idB);
    fixture.syncs.addAll([fixture.syncA, fixture.syncB]);
    return fixture;
  }

  Future<TrustStore> trust() async {
    final trust = TrustStore(_community)..trustAccount(identity.public);
    await trust.authorizeDevice(deviceA.certificate!);
    await trust.authorizeDevice(deviceB.certificate!);
    return trust;
  }

  Future<GitSync> newSync(String name, String device) => GitSync.initialize(
      worktree: Directory(p.join(root.path, name)),
      remoteUrl: remote.path,
      deviceId: device,
      segmentSize: 2);

  Future<String> git(List<String> arguments,
      {Map<String, String>? environment}) async {
    final result = await Process.run(
        'git',
        [
          '-c',
          'core.hooksPath=${p.join(root.path, 'no-hooks')}',
          '-c',
          'commit.gpgSign=false',
          '-c',
          'protocol.ext.allow=never',
          ...arguments,
        ],
        environment: {
          'GIT_CONFIG_NOSYSTEM': '1',
          'GIT_CONFIG_GLOBAL': Platform.isWindows ? 'NUL' : '/dev/null',
          'GIT_AUTHOR_NAME': 'integration-test',
          'GIT_AUTHOR_EMAIL': 'test@zaizuo.invalid',
          'GIT_COMMITTER_NAME': 'integration-test',
          'GIT_COMMITTER_EMAIL': 'test@zaizuo.invalid',
          ...?environment,
        },
        runInShell: false);
    if (result.exitCode != 0) {
      throw StateError(
          'test git ${arguments.first}: ${result.exitCode}\n${result.stderr}');
    }
    return result.stdout as String;
  }

  Future<String> remoteHead(String device) async => (await git(
          ['--git-dir=${remote.path}', 'rev-parse', 'refs/heads/dev/$device']))
      .trim();

  Future<String> pins(GitSync sync) => File(
          p.join(sync.worktree.path, '.git', 'zaizuo-sync', 'pinned_refs.json'))
      .readAsString();

  Future<String> publishRaw(
    String device,
    Map<String, String> files, {
    String? parent,
    String? gitlink,
    String fileMode = '100644',
    String message = 'untrusted integration fixture',
  }) async {
    final repo = Directory(p.join(root.path, 'attacker-${randomId(6)}'));
    await git(['init', '--template=', repo.path]);
    if (parent != null) {
      await git([
        '-C',
        repo.path,
        'fetch',
        '--no-tags',
        '--',
        remote.path,
        'refs/heads/dev/$device'
      ]);
    }
    for (final entry in files.entries) {
      final file = File(p.join(repo.path, entry.key));
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
      final blob = (await git([
        '-C',
        repo.path,
        'hash-object',
        '-w',
        '--no-filters',
        '--',
        file.path
      ]))
          .trim();
      await git([
        '-C',
        repo.path,
        'update-index',
        '--add',
        '--cacheinfo',
        '$fileMode,$blob,${entry.key}'
      ]);
    }
    if (gitlink != null) {
      await git([
        '-C',
        repo.path,
        'update-index',
        '--add',
        '--cacheinfo',
        '160000,$gitlink,untrusted-submodule'
      ]);
    }
    final tree = (await git(['-C', repo.path, 'write-tree'])).trim();
    final head = (await git([
      '-C',
      repo.path,
      'commit-tree',
      tree,
      if (parent != null) ...['-p', parent],
      '-m',
      message
    ]))
        .trim();
    await git([
      '-C',
      repo.path,
      'push',
      '--force',
      '--',
      remote.path,
      '$head:refs/heads/dev/$device'
    ]);
    return head;
  }

  Future<void> dispose() async {
    for (final sync in syncs) {
      await sync.close();
    }
    for (final store in stores) {
      await store.close();
    }
    // Root was returned by createTemp and all test data is strictly underneath.
    final absolute = p.normalize(p.absolute(root.path));
    if (p.isWithin(
            p.normalize(p.absolute(Directory.systemTemp.path)), absolute) &&
        p.basename(absolute).startsWith('zaizuo git 集成-')) {
      await root.delete(recursive: true);
    } else {
      throw StateError('refuse to remove unexpected test directory');
    }
  }
}
