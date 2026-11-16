import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_mobile_probe/client_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  ClientController? client;

  setUp(() async {
    final temporary = await Directory.systemTemp.createTemp('zsync-');
    root = Directory(await temporary.resolveSymbolicLinks());
  });
  tearDown(() async {
    await client?.shutdown();
    client = null;
    await root.delete(
      recursive: true,
    ); // Only this test's isolated temporary root.
  });

  Future<String> git(List<String> args) async {
    final result = await Process.run(
      'git',
      args,
      environment: GitCliBackend.cleanEnvironment(),
      includeParentEnvironment: false,
    );
    expect(
      result.exitCode,
      0,
      reason: 'isolated local fixture operation must succeed',
    );
    return (result.stdout as String).trim();
  }

  test('a different signed community is refused without repinning, writing or losing local messages', () async {
    final remote = '${root.path}/signed.git';
    await git(['init', '--bare', '--initial-branch=main', remote]);
    const fast = KdfParameters(memoryKiB: 32, iterations: 1);
    final owner = ClientController(
      Directory('${root.path}/a'),
      parameters: fast,
    );
    try {
      await owner.create(
        name: 'firstroot',
        displayName: '远端社区',
        password: 'Q8!FixtureR9#Local',
      );
      await owner.createSpace('远端会话');
      await owner.sendText('已有社区的消息');
      await owner.configureGit(remote);
      await owner.node!.syncOnce();
      expect(owner.error, isNull);
      expect(owner.node!.completedSyncs, 1);
      final beforeRefs = await git(['--git-dir=$remote', 'show-ref']);
      client = ClientController(Directory('${root.path}/b'), parameters: fast);
      await client!.create(
        name: 'secondroot',
        displayName: '本机社区',
        password: 'Q8!FixtureR9#Local',
      );
      await client!.createSpace('本机保留的会话');
      await client!.sendText('指纹不匹配时不能丢失');
      final room = client!.selectedConversationId!;
      final fingerprintFile = File(
        '${client!.profile!.root.path}/trust.fingerprint',
      );
      final pinnedBefore = await fingerprintFile.readAsBytes();
      final manifestBefore = client!.exportCommunity();
      await client!.configureGit(remote);
      expect(client!.error, isNull);
      await client!.sync();
      expect(client!.error, contains('[community_fingerprint_mismatch]'));
      expect(client!.node!.lastSyncError, 'community_fingerprint_mismatch');
      expect(client!.node!.completedSyncs, 0);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(client!.error, contains('[community_fingerprint_mismatch]'));
      expect(await git(['--git-dir=$remote', 'show-ref']), beforeRefs);
      expect(await fingerprintFile.readAsBytes(), pinnedBefore);
      expect(client!.exportCommunity(), manifestBefore);
      await client!.lock();
      await client!.unlock('Q8!FixtureR9#Local');
      client!.selectConversation(room);
      expect(client!.messages, hasLength(1));
      expect(
        (client!.messages.single.parts.single['data'] as Map)['text'],
        '指纹不匹配时不能丢失',
      );
    } finally {
      await owner.shutdown();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('README-initialized remote shows actionable fixed code and never overwrites main', () async {
    final remote = '${root.path}/readme.git';
    final seed = '${root.path}/seed';
    await git(['init', '--bare', '--initial-branch=main', remote]);
    await git(['init', '--initial-branch=main', seed]);
    await File('$seed/README.md')
        .writeAsString('# This is not a zaizuo community\n');
    await git(['-C', seed, 'add', 'README.md']);
    await git([
      '-C',
      seed,
      '-c',
      'user.name=fixture',
      '-c',
      'user.email=fixture@zaizuo.invalid',
      '-c',
      'commit.gpgSign=false',
      'commit',
      '-m',
      'fixture README',
    ]);
    await git(['-C', seed, 'push', remote, 'refs/heads/main:refs/heads/main']);
    final before = await git([
      '--git-dir=$remote',
      'rev-parse',
      'refs/heads/main',
    ]);
    client = ClientController(
      Directory('${root.path}/client'),
      parameters: const KdfParameters(memoryKiB: 32, iterations: 1),
    );
    await client!.create(
      name: 'syncfixture',
      displayName: '同步测试',
      password: 'Q8!FixtureR9#Local',
    );
    await client!.createSpace('持久化会话');
    await client!.sendText('main无效时消息也必须保留在本机');
    final conversation = client!.selectedConversationId!;
    await client!.configureGit(remote);
    expect(client!.error, isNull);
    // Reproduces the real UI order: account -> space/message -> configure -> sync.
    await client!.sync();
    expect(client!.error, contains('[invalid_manifest_tree]'));
    expect(client!.error, contains('不会覆盖远端'));
    expect(client!.error, isNot(contains('operation_failed')));
    expect(client!.node!.lastSyncError, 'invalid_manifest_tree');
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(
      client!.error,
      contains('[invalid_manifest_tree]'),
      reason: 'node error stream must not replace the cause with git_failed',
    );
    final after = await git([
      '--git-dir=$remote',
      'rev-parse',
      'refs/heads/main',
    ]);
    expect(after, before);
    expect(
      (await git([
        '--git-dir=$remote',
        'for-each-ref',
        '--format=%(refname)',
        'refs/heads',
      ])).split('\n'),
      ['refs/heads/main'],
    );
    client!.selectConversation(conversation);
    expect(client!.messages, hasLength(1));
    expect(
      (client!.messages.single.parts.single['data'] as Map)['text'],
      'main无效时消息也必须保留在本机',
    );
  });
}
