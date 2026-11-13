import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_runtime/zaizuo_runtime.dart';

const fixturePassword = 'Native!72#LocalOnly9';
const fixtureKdf = KdfParameters(memoryKiB: 32, iterations: 1, parallelism: 1);
const fixtureLobby = 'native-lobby#main';

typedef BackendFactory = GitBackend Function();

/// All Process use lives in this test oracle, never in the native backend.
/// No network, credentials, account directories, or production Git config.
class NativeFixture {
  final Directory root;
  final Directory remote;
  final BackendFactory backendFactory;
  final repositories = <GitSync>[];
  final nodes = <ZaizuoNode>[];
  late LocalProfile alice;
  late LocalProfile bob;
  late GitSync cli;
  late GitSync native;
  late ZaizuoNode a;
  late ZaizuoNode b;

  NativeFixture._(this.root, this.remote, this.backendFactory);

  static Future<NativeFixture> create(
    BackendFactory backendFactory, {
    bool profiles = false,
  }) async {
    final root = await Directory.systemTemp.createTemp(
      'zaizuo-native-interop-',
    );
    final fixture = NativeFixture._(
      root,
      Directory(p.join(root.path, 'remote 裸.git')),
      backendFactory,
    );
    fixture.validateCleanupPath();
    try {
      await fixture.git([
        'init',
        '--bare',
        '--template=',
        '--object-format=sha1',
        '--initial-branch=main',
        fixture.remote.path,
      ]);
      if (profiles) await fixture.createProfiles();
      return fixture;
    } catch (_) {
      await fixture.dispose();
      rethrow;
    }
  }

  Future<void> createProfiles() async {
    final aliceDir = Directory(p.join(root.path, 'alice'));
    await LocalProfile.initialize(
      aliceDir,
      name: 'nativealice',
      displayName: 'Native Alice',
      password: fixturePassword,
      parameters: fixtureKdf,
    );
    alice = await LocalProfile.open(aliceDir, fixturePassword);
    final bobDir = Directory(p.join(root.path, 'bob'));
    await LocalProfile.initialize(
      bobDir,
      name: 'nativebob',
      displayName: 'Native Bob',
      password: fixturePassword,
      parameters: fixtureKdf,
      community: alice.manifest,
      pinnedFingerprint: await alice.manifest.fingerprint(),
    );
    bob = await LocalProfile.open(bobDir, fixturePassword);
    cli = await repository(
      'CLI clone 中文',
      alice.device.certificate!.id,
      nativeBackend: false,
    );
    native = await repository('native clone 中文', bob.device.certificate!.id);
    a = await ZaizuoNode.open(profile: alice, git: cli);
    nodes.add(a);
    await a.admit(await bob.joinRequest());
    b = await ZaizuoNode.open(profile: bob, git: native);
    nodes.add(b);
    await exchange();
    await a.execute(
      operation: 'space.create',
      params: {
        'id': 'native-lobby',
        'title': 'Native Lobby',
        'public_channel': true,
      },
    );
    await exchange();
    await b.execute(operation: 'space.join', params: {'space': 'native-lobby'});
    await exchange();
  }

  Future<GitSync> repository(
    String name,
    String deviceId, {
    bool nativeBackend = true,
  }) async {
    final worktree = Directory(p.join(root.path, name));
    final repository = nativeBackend
        ? await GitSync.initializeWithBackend(
            backend: backendFactory(),
            worktree: worktree,
            remoteUrl: remote.path,
            deviceId: deviceId,
          )
        : await GitSync.initialize(
            worktree: worktree,
            remoteUrl: remote.path,
            deviceId: deviceId,
          );
    repositories.add(repository);
    return repository;
  }

  Future<void> exchange() async {
    await a.syncOnce();
    await b.syncOnce();
    await a.syncOnce();
    await b.syncOnce();
  }

  Future<void> reopenNative() async {
    await b.close();
    await native.close();
    bob = await LocalProfile.open(bob.root, fixturePassword);
    native = await repository('native clone 中文', bob.device.certificate!.id);
    b = await ZaizuoNode.open(profile: bob, git: native);
    nodes.add(b);
  }

  String attachmentRef(String id) => 'refs/heads/attachment/$id';
  Future<String> head(String ref) async =>
      (await git(['--git-dir=${remote.path}', 'rev-parse', ref])).trim();
  File metadata(GitSync repository, String name) =>
      File(p.join(repository.worktree.path, '.git', 'zaizuo-sync', name));
  Future<String> pins(GitSync repository) =>
      metadata(repository, 'pinned_refs.json').readAsString();
  Future<String> attachmentPins(GitSync repository) =>
      metadata(repository, 'attachment_pins.json').readAsString();
  Future<(String, File)> ciphertext(List<int> bytes) async {
    final id = await sha256Hex(bytes);
    final file = File(p.join(root.path, '$id.bin'));
    await file.writeAsBytes(bytes, flush: true);
    return (id, file);
  }

  Map<String, String> get gitEnvironment => {
    'GIT_CONFIG_NOSYSTEM': '1',
    'GIT_CONFIG_GLOBAL': Platform.isWindows ? 'NUL' : '/dev/null',
    'GIT_TERMINAL_PROMPT': '0',
    'GIT_AUTHOR_NAME': 'native-fixture',
    'GIT_AUTHOR_EMAIL': 'native-fixture@invalid',
    'GIT_COMMITTER_NAME': 'native-fixture',
    'GIT_COMMITTER_EMAIL': 'native-fixture@invalid',
  };

  Future<ProcessResult> rawGit(
    List<String> args, {
    bool binary = false,
    Map<String, String> environment = const {},
  }) => Process.run(
    'git',
    [
      '-c',
      'core.hooksPath=${p.join(root.path, 'empty-hooks')}',
      '-c',
      'commit.gpgSign=false',
      '-c',
      'protocol.ext.allow=never',
      ...args,
    ],
    runInShell: false,
    environment: {...gitEnvironment, ...environment},
    stdoutEncoding: binary ? null : utf8,
  );

  Future<String> git(
    List<String> args, {
    Map<String, String> environment = const {},
  }) async {
    final result = await rawGit(args, environment: environment);
    if (result.exitCode != 0) {
      throw StateError(
        'fixture git ${args.first}: ${result.exitCode}\n${result.stderr}',
      );
    }
    return result.stdout as String;
  }

  Future<Uint8List> remoteObject(String id) async {
    final result = await rawGit([
      '--git-dir=${remote.path}',
      'show',
      '${attachmentRef(id)}:object.bin',
    ], binary: true);
    if (result.exitCode != 0)
      throw StateError('missing attachment: ${result.stderr}');
    return Uint8List.fromList(result.stdout as List<int>);
  }

  /// Constructs hostile trees directly, bypassing checkout and platform file modes.
  Future<String> publishRaw(
    String ref,
    Map<String, List<int>> files, {
    String mode = '100644',
    String? parent,
    String? gitlink,
  }) async {
    final repo = Directory(p.join(root.path, 'attacker-${randomId(6)}'));
    await git(['init', '--template=', repo.path]);
    if (parent != null || gitlink != null) {
      await git([
        '-C',
        repo.path,
        'fetch',
        '--no-tags',
        '--',
        remote.path,
        ref,
      ]);
    }
    for (final entry in files.entries) {
      final file = File(p.join(repo.path, 'oracle-blob'));
      await file.writeAsBytes(entry.value);
      final blob = (await git([
        '-C',
        repo.path,
        'hash-object',
        '-w',
        '--no-filters',
        '--',
        file.path,
      ])).trim();
      await git([
        '-C',
        repo.path,
        'update-index',
        '--add',
        '--cacheinfo',
        '$mode,$blob,${entry.key}',
      ]);
    }
    if (gitlink != null) {
      await git([
        '-C',
        repo.path,
        'update-index',
        '--add',
        '--cacheinfo',
        '160000,$gitlink,untrusted-submodule',
      ]);
    }
    final tree = (await git(['-C', repo.path, 'write-tree'])).trim();
    final commit = (await git([
      '-C',
      repo.path,
      'commit-tree',
      tree,
      if (parent != null) ...['-p', parent],
      '-m',
      'hostile fixture',
    ])).trim();
    await git([
      '-C',
      repo.path,
      'push',
      '--force',
      '--',
      remote.path,
      '$commit:$ref',
    ]);
    return commit;
  }

  void validateCleanupPath() {
    final absolute = p.normalize(p.absolute(root.path));
    final temp = p.normalize(p.absolute(Directory.systemTemp.path));
    if (!p.isWithin(temp, absolute) ||
        !p.basename(absolute).startsWith('zaizuo-native-interop-')) {
      throw StateError('refuse unsafe native fixture cleanup: $absolute');
    }
  }

  Future<void> dispose() async {
    try {
      for (final node in nodes) {
        await node.close();
      }
      for (final repository in repositories) {
        await repository.close();
      }
    } finally {
      validateCleanupPath();
      if (await root.exists()) await root.delete(recursive: true);
    }
  }
}
