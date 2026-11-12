import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:zaizuo_core/src/codec.dart';
import 'package:zaizuo_core/src/community_git.dart';
import 'package:zaizuo_core/src/config.dart';
import 'package:zaizuo_core/src/crypto.dart';
import 'package:zaizuo_core/src/devices.dart';
import 'package:zaizuo_core/src/events.dart';
import 'package:zaizuo_core/src/git_sync.dart';
import 'package:zaizuo_core/src/store.dart';

void main() {
  late _CommunityFixture fixture;
  setUp(() async {
    fixture = await _CommunityFixture.create();
  });
  tearDown(() async {
    await fixture.dispose();
  });

  test(
      'main initially absent is legal, then signed revisions reach another clone',
      () async {
    expect(await fixture.reader.pull(), isNull);
    expect(await fixture.writer.publish(fixture.first), 1);
    final firstHead = await fixture.head();
    expect(await fixture.writer.publish(fixture.first), 0);
    expect(await fixture.head(), firstHead);
    expect((await fixture.reader.pull())!.toJson(), fixture.first.toJson());
    final second = await fixture.next(fixture.first);
    final third = await fixture.next(second);
    expect(await fixture.writer.publish(second), 1);
    expect(await fixture.writer.publish(third), 1);
    final history = await fixture.reader.readHistory();
    expect(history.map((m) => m.revision), [1, 2, 3]);
    expect(history.last.toJson(), third.toJson());
    expect(history.last.accounts.map((a) => a.accountId),
        contains(fixture.member.public.accountId));
    expect(history.last.body['settings'], contains('devices'));
    final tree = await fixture.git([
      '--git-dir=${fixture.remote.path}',
      'ls-tree',
      '-r',
      '--name-only',
      'refs/heads/main'
    ]);
    expect(tree.trim().split('\n'), [
      'manifest.json',
      'manifests/00000001.json',
      'manifests/00000002.json',
      'manifests/00000003.json',
    ]);
    expect(
        await File(p.join(fixture.readerRepo.worktree.path, 'manifest.json'))
            .exists(),
        isFalse);
    expect(tree, isNot(contains('checkpoint')));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('main and device branch synchronization are independent', () async {
    final trust = TrustStore(fixture.first.communityId)
      ..trustAccount(fixture.owner.public);
    await trust.authorizeDevice(fixture.device.certificate!);
    final sender = await FileEventStore.open(
        Directory(p.join(fixture.root.path, 'sender-store')), trust);
    final receiver = await FileEventStore.open(
        Directory(p.join(fixture.root.path, 'receiver-store')), trust);
    fixture.stores.addAll([sender, receiver]);
    await sender.append(
        device: fixture.device,
        key: ConversationKey.generate('main-independent-conversation', 1),
        body: {'text': 'signed ciphertext'});
    expect(await fixture.writerRepo.push(sender), 1);
    final deviceRef = fixture.writerRepo.branchRef;
    final deviceHead = (await fixture
            .git(['--git-dir=${fixture.remote.path}', 'rev-parse', deviceRef]))
        .trim();
    await fixture.writer.publish(fixture.first);
    expect(
        (await fixture.git(
                ['--git-dir=${fixture.remote.path}', 'rev-parse', deviceRef]))
            .trim(),
        deviceHead);
    final mainHead = await fixture.head();
    expect(await fixture.readerRepo.pull(receiver), 1);
    expect((await fixture.reader.pull())!.revision, 1);
    expect(await fixture.head(), mainHead);
    expect(receiver.allEnvelopes.single.origin, fixture.device.certificate!.id);
  });

  test('wrong externally pinned root is rejected without trusting remote owner',
      () async {
    await fixture.writer.publish(fixture.first);
    final wrongRepo = await fixture.newRepo('wrong-root-clone', 'c' * 64);
    fixture.repos.add(wrongRepo);
    final wrong =
        CommunityGit(repository: wrongRepo, pinnedFingerprint: '0' * 64);
    await expectLater(wrong.pull(), throwsStateError);
    final checkpoint = jsonObject(await fixture.checkpoint(wrongRepo));
    expect(checkpoint['revision'], 0);
    expect(checkpoint['head'], isNull);
  });

  test(
      'invalid signer is rejected before starting network credentials or transport',
      () async {
    final outsider = await Identity.create('outsider');
    final invalid = await CommunityManifest.create(outsider,
        communityId: fixture.first.communityId);
    final remoteConfig = File(p.join(fixture.remote.path, 'config'));
    // If transport were reached this deliberately forbidden remote config
    // would produce unsafe_local_remote instead of the signature error.
    await remoteConfig.writeAsString('[include]\n path=not-trusted\n',
        mode: FileMode.append);
    await expectLater(fixture.writer.publish(invalid), throwsStateError);
    final config =
        File(p.join(fixture.writerRepo.worktree.path, '.git', 'config'));
    expect(await config.readAsString(), isNot(contains('credential')));
  });

  test(
      'bad signature and forbidden executable main tree never advance checkpoint',
      () async {
    final json = fixture.first.toJson()
      ..['signature'] = base64Encode(List<int>.filled(64, 0));
    await fixture.raw({'manifest.json': json, 'manifests/00000001.json': json});
    await expectLater(fixture.reader.pull(), throwsStateError);
    final before = await fixture.checkpoint(fixture.readerRepo);
    await fixture.raw(fixture.files([fixture.first]), fileMode: '100755');
    await expectLater(
        fixture.reader.pull(),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'invalid_manifest_tree')));
    expect(await fixture.checkpoint(fixture.readerRepo), before);
  });

  test(
      'bad intermediate signature is checked even when latest signature is valid',
      () async {
    final brokenJson = fixture.first.toJson()
      ..['signature'] = base64Encode(List<int>.filled(64, 0));
    final broken = CommunityManifest.fromJson(brokenJson);
    final second = await CommunityManifest.create(fixture.owner,
        communityId: fixture.first.communityId,
        revision: 2,
        previousHash: await objectHash(broken.toJson()));
    await fixture.raw({
      'manifest.json': second.toJson(),
      'manifests/00000001.json': broken.toJson(),
      'manifests/00000002.json': second.toJson(),
    });
    await expectLater(fixture.reader.pull(), throwsStateError);
    expect(jsonObject(await fixture.checkpoint(fixture.readerRepo))['revision'],
        0);
  });

  test('missing intermediate revision and wrong previous hash fail closed',
      () async {
    final second = await fixture.next(fixture.first);
    final third = await fixture.next(second);
    await fixture.raw({
      'manifest.json': third.toJson(),
      'manifests/00000001.json': fixture.first.toJson(),
      'manifests/00000003.json': third.toJson(),
    });
    await expectLater(
        fixture.reader.pull(),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'manifest_gap')));
    final badSecond = await CommunityManifest.create(fixture.owner,
        communityId: fixture.first.communityId,
        revision: 2,
        previousHash: '0' * 64);
    await fixture.raw(fixture.files([fixture.first, badSecond]));
    await expectLater(fixture.reader.pull(), throwsStateError);
  });

  test('latest root pointer must match newest full chain record', () async {
    final second = await fixture.next(fixture.first);
    final files = fixture.files([fixture.first, second])
      ..['manifest.json'] = fixture.first.toJson();
    await fixture.raw(files);
    await expectLater(
        fixture.reader.pull(),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'invalid_manifest_tree')));
  });

  test('published main cannot roll back after checkpoint reopening', () async {
    await fixture.writer.publish(fixture.first);
    final oldHead = await fixture.head();
    final second = await fixture.next(fixture.first);
    await fixture.writer.publish(second);
    await fixture.reader.pull();
    final before = await fixture.checkpoint(fixture.readerRepo);
    final reopenedRepo = await fixture.newRepo('reader clone 中文', 'b' * 64);
    fixture.repos.add(reopenedRepo);
    final reopened = CommunityGit(
        repository: reopenedRepo, pinnedFingerprint: fixture.fingerprint);
    await fixture.git([
      '-C',
      fixture.writerRepo.worktree.path,
      'push',
      '--force',
      '--',
      fixture.remote.path,
      '$oldHead:refs/heads/main'
    ]);
    await expectLater(
        reopened.pull(),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'remote_rewrite')));
    expect(await fixture.checkpoint(reopenedRepo), before);
  });

  test('unrelated force-push with the same signed manifest is still a fork',
      () async {
    await fixture.writer.publish(fixture.first);
    await fixture.reader.pull();
    final before = await fixture.checkpoint(fixture.readerRepo);
    await fixture.raw(fixture.files([fixture.first]));
    await expectLater(
        fixture.reader.pull(),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'remote_rewrite')));
    expect(await fixture.checkpoint(fixture.readerRepo), before);
  });

  test('a Git descendant cannot replace already checkpointed signed revisions',
      () async {
    await fixture.writer.publish(fixture.first);
    final second = await fixture.next(fixture.first);
    await fixture.writer.publish(second);
    await fixture.reader.pull();
    final before = await fixture.checkpoint(fixture.readerRepo);
    final alternate = await CommunityManifest.create(fixture.owner,
        communityId: fixture.first.communityId,
        revision: 2,
        previousHash: await objectHash(fixture.first.toJson()),
        title: 'alternate history');
    await fixture.raw(fixture.files([fixture.first, alternate]),
        parent: await fixture.head());
    await expectLater(
        fixture.reader.pull(),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'manifest_rewrite')));
    expect(await fixture.checkpoint(fixture.readerRepo), before);
  });

  test('deleting a known main is an alarm and cannot be silently recreated',
      () async {
    await fixture.writer.publish(fixture.first);
    await fixture.reader.pull();
    await fixture.git([
      '-C',
      fixture.writerRepo.worktree.path,
      'push',
      '--',
      fixture.remote.path,
      ':refs/heads/main'
    ]);
    await expectLater(
        fixture.reader.pull(),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'remote_deleted')));
    await expectLater(
        fixture.writer.publish(fixture.first),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'remote_deleted')));
  });

  test('missing local checkpoint never resets observed main trust', () async {
    await fixture.writer.publish(fixture.first);
    await fixture.reader.pull();
    final checkpoint = File(p.join(fixture.readerRepo.worktree.path, '.git',
        'zaizuo-sync', 'community_checkpoint.json'));
    await checkpoint.delete();
    await expectLater(
        fixture.reader.pull(),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'missing_checkpoint')));
  });

  test('skipped publication revision cannot update main', () async {
    final third = await CommunityManifest.create(fixture.owner,
        communityId: fixture.first.communityId,
        revision: 3,
        previousHash: '0' * 64);
    await expectLater(
        fixture.writer.publish(third),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'manifest_gap')));
    expect(await fixture.reader.pull(), isNull);
  });

  test(
      'local bare main transport refuses active remote hooks without executing them',
      () async {
    final marker = File(p.join(fixture.root.path, 'remote-hook-ran'));
    final hook = File(p.join(fixture.remote.path, 'hooks', 'pre-receive'));
    await hook.parent.create();
    await hook.writeAsString(
        '#!/bin/sh\necho bad > "${marker.path.replaceAll('\\', '/')}"\nexit 42\n');
    if (!Platform.isWindows) await Process.run('chmod', ['+x', hook.path]);
    await expectLater(
        fixture.writer.publish(fixture.first),
        throwsA(isA<GitSyncException>()
            .having((e) => e.code, 'code', 'unsafe_local_remote')));
    expect(await marker.exists(), isFalse);
  });
}

class _CommunityFixture {
  final Directory root;
  final Directory remote;
  final Identity owner;
  final Identity member;
  final DeviceCredentials device;
  final CommunityManifest first;
  final String fingerprint;
  late GitSync writerRepo;
  late GitSync readerRepo;
  late CommunityGit writer;
  late CommunityGit reader;
  final repos = <GitSync>[];
  final stores = <FileEventStore>[];
  _CommunityFixture(this.root, this.remote, this.owner, this.member,
      this.device, this.first, this.fingerprint);

  static Future<_CommunityFixture> create() async {
    final root = await Directory.systemTemp.createTemp('zaizuo main 集成-');
    final remote = Directory(p.join(root.path, 'main remote.git'));
    final owner = await Identity.create('community_root');
    final member = await Identity.create('member');
    final device = await DeviceCredentials.create();
    final initial = await CommunityManifest.create(owner,
        communityId: 'main-test-community');
    await device.authorize(owner, initial.communityId);
    final first = await CommunityManifest.create(owner,
        communityId: initial.communityId,
        settings: {
          'devices': [device.certificate!.toJson()],
          'keys': []
        });
    final fixture = _CommunityFixture(
        root, remote, owner, member, device, first, await first.fingerprint());
    await fixture.git(
        ['init', '--bare', '--template=', '--object-format=sha1', remote.path]);
    fixture.writerRepo =
        await fixture.newRepo('writer clone 中文', device.certificate!.id);
    fixture.readerRepo = await fixture.newRepo('reader clone 中文', 'b' * 64);
    fixture.repos.addAll([fixture.writerRepo, fixture.readerRepo]);
    fixture.writer = CommunityGit(
        repository: fixture.writerRepo, pinnedFingerprint: fixture.fingerprint);
    fixture.reader = CommunityGit(
        repository: fixture.readerRepo, pinnedFingerprint: fixture.fingerprint);
    return fixture;
  }

  Future<CommunityManifest> next(CommunityManifest previous) async =>
      CommunityManifest.create(
        owner,
        communityId: previous.communityId,
        revision: previous.revision + 1,
        previousHash: await objectHash(previous.toJson()),
        accounts: [member.public],
        settings: {
          'devices': [device.certificate!.toJson()],
          'keys': []
        },
      );

  Map<String, dynamic> files(List<CommunityManifest> history) => {
        'manifest.json': history.last.toJson(),
        for (final m in history)
          'manifests/${m.revision.toString().padLeft(8, '0')}.json': m.toJson(),
      };

  Future<GitSync> newRepo(String name, String deviceId) => GitSync.initialize(
      worktree: Directory(p.join(root.path, name)),
      remoteUrl: remote.path,
      deviceId: deviceId);

  Future<String> checkpoint(GitSync repo) => File(p.join(repo.worktree.path,
          '.git', 'zaizuo-sync', 'community_checkpoint.json'))
      .readAsString();

  Future<String> head() async =>
      (await git(['--git-dir=${remote.path}', 'rev-parse', 'refs/heads/main']))
          .trim();

  Future<String> git(List<String> arguments) async {
    final result = await Process.run(
        'git',
        [
          '-c',
          'core.hooksPath=${p.join(root.path, 'empty-hooks')}',
          '-c',
          'commit.gpgSign=false',
          '-c',
          'protocol.ext.allow=never',
          ...arguments,
        ],
        runInShell: false,
        environment: {
          'GIT_CONFIG_NOSYSTEM': '1',
          'GIT_CONFIG_GLOBAL': Platform.isWindows ? 'NUL' : '/dev/null',
          'GIT_AUTHOR_NAME': 'main-test',
          'GIT_AUTHOR_EMAIL': 'main@invalid',
          'GIT_COMMITTER_NAME': 'main-test',
          'GIT_COMMITTER_EMAIL': 'main@invalid',
        });
    if (result.exitCode != 0)
      throw StateError('fixture git ${arguments.first}: ${result.stderr}');
    return result.stdout as String;
  }

  Future<String> raw(Map<String, dynamic> files,
      {String? parent, String fileMode = '100644'}) async {
    final repo = Directory(p.join(root.path, 'untrusted-${randomId(6)}'));
    await git(['init', '--template=', repo.path]);
    if (parent != null)
      await git([
        '-C',
        repo.path,
        'fetch',
        '--no-tags',
        '--',
        remote.path,
        'refs/heads/main'
      ]);
    for (final file in files.entries) {
      final blobFile = File(p.join(repo.path, 'blob'));
      await blobFile.writeAsString('${canonicalJson(file.value)}\n');
      final blob = (await git([
        '-C',
        repo.path,
        'hash-object',
        '-w',
        '--no-filters',
        '--',
        blobFile.path
      ]))
          .trim();
      await git([
        '-C',
        repo.path,
        'update-index',
        '--add',
        '--cacheinfo',
        '$fileMode,$blob,${file.key}'
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
      'untrusted main fixture'
    ]))
        .trim();
    await git([
      '-C',
      repo.path,
      'push',
      '--force',
      '--',
      remote.path,
      '$head:refs/heads/main'
    ]);
    return head;
  }

  Future<void> dispose() async {
    for (final repo in repos) {
      await repo.close();
    }
    for (final store in stores) {
      await store.close();
    }
    final absolute = p.normalize(p.absolute(root.path));
    if (p.isWithin(
            p.normalize(p.absolute(Directory.systemTemp.path)), absolute) &&
        p.basename(absolute).startsWith('zaizuo main 集成-')) {
      await root.delete(recursive: true);
    } else {
      throw StateError('unexpected main test cleanup path');
    }
  }
}
