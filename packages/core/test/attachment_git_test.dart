import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:zaizuo_core/src/attachment_git.dart';
import 'package:zaizuo_core/src/codec.dart';
import 'package:zaizuo_core/src/config.dart';
import 'package:zaizuo_core/src/crypto.dart';
import 'package:zaizuo_core/src/devices.dart';
import 'package:zaizuo_core/src/events.dart';
import 'package:zaizuo_core/src/git_sync.dart';
import 'package:zaizuo_core/src/store.dart';

void main() {
  late _Attachments fixture;
  setUp(() async {
    fixture = await _Attachments.create();
  });
  tearDown(() async {
    await fixture.dispose();
  });

  test(
      'binary ciphertext round-trips by exact ref without main or dev tree changes',
      () async {
    final identity = await Identity.create('attachmenttest');
    final device = await DeviceCredentials.create();
    final manifest = await CommunityManifest.create(identity);
    await device.authorize(identity, manifest.communityId);
    final trust = TrustStore(manifest.communityId)
      ..trustAccount(identity.public);
    await trust.authorizeDevice(device.certificate!);
    final store = await FileEventStore.open(
        Directory(p.join(fixture.root.path, 'events')), trust);
    fixture.stores.add(store);
    final sender = await fixture.repo('content-sender', device.certificate!.id);
    await sender.publishManifest(manifest,
        pinnedFingerprint: await manifest.fingerprint());
    await store.append(
        device: device,
        key: ConversationKey.generate('private', 1),
        body: {'message': 'content'});
    await sender.push(store);
    final mainHead = await fixture.head('refs/heads/main');
    final devHead = await fixture.head(sender.branchRef);
    final bytes = Uint8List.fromList(List<int>.generate(4096, (i) => i % 256));
    final (id, file) = await fixture.ciphertext(bytes);
    final transport = AttachmentGit(repository: fixture.a);
    await transport.publishAttachment(objectId: id, ciphertext: file);
    expect(
        await AttachmentGit(repository: fixture.b).fetchAttachment(id), bytes);
    expect(await fixture.head('refs/heads/main'), mainHead);
    expect(await fixture.head(sender.branchRef), devHead);
    final tree = await fixture.git([
      '--git-dir=${fixture.remote.path}',
      'ls-tree',
      '-r',
      '--name-only',
      fixture.ref(id)
    ]);
    expect(tree.trim(), 'object.bin');
    expect(await File(p.join(fixture.b.worktree.path, 'object.bin')).exists(),
        isFalse);
    expect(await fixture.pin(fixture.b), contains(id));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
      'same ciphertext repeated and concurrent publishers deduplicate to one commit',
      () async {
    final (id, file) =
        await fixture.ciphertext(List<int>.generate(1024, (i) => i % 251));
    await Future.wait([
      fixture.a.publishAttachment(objectId: id, ciphertext: file),
      fixture.b.publishAttachment(objectId: id, ciphertext: file),
    ]);
    final head = await fixture.head(fixture.ref(id));
    await fixture.a.publishAttachment(objectId: id, ciphertext: file);
    await fixture.b.publishAttachment(objectId: id, ciphertext: file);
    expect(await fixture.head(fixture.ref(id)), head);
    expect(
        (await fixture.git([
          '--git-dir=${fixture.remote.path}',
          'rev-list',
          '--count',
          fixture.ref(id)
        ]))
            .trim(),
        '1');
    expect(await fixture.b.fetchAttachment(id), await file.readAsBytes());
  });

  test(
      'only requested attachment is fetched; unrelated refs and pack objects remain absent',
      () async {
    final (firstId, first) =
        await fixture.ciphertext(List<int>.generate(2048, (i) => i % 255));
    final (secondId, second) = await fixture
        .ciphertext(List<int>.generate(3072, (i) => (i + 1) % 256));
    await fixture.a.publishAttachment(objectId: firstId, ciphertext: first);
    await fixture.a.publishAttachment(objectId: secondId, ciphertext: second);
    final secondHead = await fixture.head(fixture.ref(secondId));
    await fixture.b.fetchAttachment(firstId);
    final result = await fixture
        .rawGit(['-C', fixture.b.worktree.path, 'cat-file', '-e', secondHead]);
    expect(result.exitCode, isNot(0));
    final pins = jsonObject(await fixture.pin(fixture.b))['objects'] as Map;
    expect(pins.keys, [firstId]);
    expect(
        await fixture.b.fetchAttachment(secondId), await second.readAsBytes());
  });

  test(
      'wrong hash, malformed object id and oversized local file fail before unsafe remote config',
      () async {
    final (id, file) = await fixture.ciphertext([0, 255, 1, 254]);
    final config = File(p.join(fixture.remote.path, 'config'));
    await config.writeAsString('[include]\n path=untrusted\n',
        mode: FileMode.append);
    await expectLater(
        fixture.a.publishAttachment(objectId: '0' * 64, ciphertext: file),
        failure('attachment_hash'));
    await expectLater(
        fixture.a.publishAttachment(objectId: '../bad', ciphertext: file),
        throwsFormatException);
    final big = File(p.join(fixture.root.path, 'too-big.bin'));
    final handle = await big.open(mode: FileMode.write);
    await handle.truncate(GitSync.maxAttachmentBytes + 1);
    await handle.close();
    await expectLater(
        fixture.a.publishAttachment(objectId: id, ciphertext: big),
        failure('attachment_limit'));
    await expectLater(
        fixture.a.fetchAttachment(id, maxBytes: GitSync.maxAttachmentBytes + 1),
        throwsArgumentError);
  });

  test(
      'receiver size cap checks blob before returning bytes and does not advance pins',
      () async {
    final (id, file) = await fixture.ciphertext(List<int>.filled(1024, 127));
    await fixture.a.publishAttachment(objectId: id, ciphertext: file);
    await expectLater(fixture.b.fetchAttachment(id, maxBytes: 512),
        failure('attachment_limit'));
    expect(jsonObject(await fixture.pin(fixture.b))['objects'], isEmpty);
    expect(await fixture.b.fetchAttachment(id, maxBytes: 1024),
        await file.readAsBytes());
  });

  test('bad remote hash cannot be fetched or overwritten by honest publisher',
      () async {
    final (id, file) = await fixture.ciphertext([0, 1, 2, 255, 254]);
    await fixture.publishRaw(id, {
      'object.bin': [9, 9, 9]
    });
    await expectLater(
        fixture.b.fetchAttachment(id), failure('attachment_hash'));
    final head = await fixture.head(fixture.ref(id));
    await expectLater(
        fixture.a.publishAttachment(objectId: id, ciphertext: file),
        failure('attachment_hash'));
    expect(await fixture.head(fixture.ref(id)), head);
    expect(jsonObject(await fixture.pin(fixture.b))['objects'], isEmpty);
  });

  test('remote executable, symlink, extra files and gitlinks are all refused',
      () async {
    final bytes = [5, 4, 3, 2, 1];
    final id = await sha256Hex(bytes);
    for (final mode in ['100755', '120000']) {
      await fixture.publishRaw(id, {'object.bin': bytes}, mode: mode);
      await expectLater(
          fixture.b.fetchAttachment(id), failure('attachment_collision'));
    }
    final parent = await fixture.publishRaw(id, {
      'object.bin': bytes,
      '.gitattributes': utf8.encode('* filter=unsafe\n')
    });
    await expectLater(
        fixture.b.fetchAttachment(id), failure('attachment_collision'));
    await fixture.publishRaw(id, {'object.bin': bytes}, gitlink: parent);
    await expectLater(
        fixture.b.fetchAttachment(id), failure('attachment_collision'));
  });

  test(
      'remote 20MiB+ object is rejected without pinning even with matching ciphertext hash',
      () async {
    final bytes = Uint8List(GitSync.maxAttachmentBytes + 1);
    final id = await sha256Hex(bytes);
    await fixture.publishRaw(id, {'object.bin': bytes});
    await expectLater(
        fixture.b.fetchAttachment(id), failure('attachment_limit'));
    expect(jsonObject(await fixture.pin(fixture.b))['objects'], isEmpty);
  });

  test(
      'seen immutable ref rejects a force-pushed commit even when ciphertext is unchanged',
      () async {
    final (id, file) = await fixture.ciphertext([7, 8, 9, 0]);
    await fixture.a.publishAttachment(objectId: id, ciphertext: file);
    await fixture.b.fetchAttachment(id);
    final before = await fixture.pin(fixture.b);
    await fixture.publishRaw(id, {'object.bin': await file.readAsBytes()},
        message: 'changed immutable metadata');
    await expectLater(
        fixture.b.fetchAttachment(id), failure('attachment_rewrite'));
    await expectLater(
        fixture.a.publishAttachment(objectId: id, ciphertext: file),
        failure('attachment_rewrite'));
    expect(await fixture.pin(fixture.b), before);
  });

  test(
      'seen deleted ref is rejected after reopening and cannot be recreated silently',
      () async {
    final (id, file) = await fixture.ciphertext([10, 11, 12]);
    await fixture.a.publishAttachment(objectId: id, ciphertext: file);
    await fixture.b.fetchAttachment(id);
    await fixture.b.close();
    final reopened = await fixture.repo('clone-b', 'b' * 64);
    await fixture.git([
      '-C',
      fixture.a.worktree.path,
      'push',
      '--',
      fixture.remote.path,
      ':${fixture.ref(id)}'
    ]);
    await expectLater(
        reopened.fetchAttachment(id), failure('attachment_deleted'));
    await expectLater(
        fixture.a.publishAttachment(objectId: id, ciphertext: file),
        failure('attachment_deleted'));
    await expectLater(
        reopened.fetchAttachment('f' * 64), failure('attachment_not_found'));
  });

  test('missing attachment pin file does not reset trust', () async {
    final (id, file) = await fixture.ciphertext([20, 21, 22]);
    await fixture.a.publishAttachment(objectId: id, ciphertext: file);
    await fixture.b.fetchAttachment(id);
    final pins = File(p.join(fixture.b.worktree.path, '.git', 'zaizuo-sync',
        'attachment_pins.json'));
    await pins.delete();
    await expectLater(
        fixture.b.fetchAttachment(id), failure('missing_attachment_pins'));
  });

  test(
      'local source symlinks and local/remote automatic Git configuration are not executed',
      () async {
    final (id, file) = await fixture.ciphertext([30, 31, 32]);
    final link = Link(p.join(fixture.root.path, 'ciphertext-link.bin'));
    var canLink = true;
    try {
      await link.create(file.path);
    } on FileSystemException {
      canLink = false;
    }
    if (canLink) {
      await expectLater(
          fixture.a
              .publishAttachment(objectId: id, ciphertext: File(link.path)),
          failure('unsafe_attachment_path'));
    }
    final hook = File(p.join(fixture.remote.path, 'hooks', 'pre-receive'));
    await hook.parent.create();
    final marker = File(p.join(fixture.root.path, 'hook-executed'));
    await hook.writeAsString(
        '#!/bin/sh\necho bad > "${marker.path.replaceAll('\\', '/')}"\nexit 42\n');
    if (!Platform.isWindows) await Process.run('chmod', ['+x', hook.path]);
    await expectLater(
        fixture.a.publishAttachment(objectId: id, ciphertext: file),
        failure('unsafe_local_remote'));
    expect(await marker.exists(), isFalse);
    await hook.delete();
    final config = File(p.join(fixture.a.worktree.path, '.git', 'config'));
    await config.writeAsString('[include]\n path=not-trusted\n',
        mode: FileMode.append);
    await expectLater(
        fixture.a.publishAttachment(objectId: id, ciphertext: file),
        failure('unsafe_configuration'));
    expect(await marker.exists(), isFalse);
  });
}

Matcher failure(String code) => throwsA(
    isA<GitSyncException>().having((error) => error.code, 'code', code));

class _Attachments {
  final Directory root;
  final Directory remote;
  late GitSync a;
  late GitSync b;
  final repositories = <GitSync>[];
  final stores = <FileEventStore>[];
  _Attachments(this.root, this.remote);

  static Future<_Attachments> create() async {
    final root = await Directory.systemTemp.createTemp('zaizuo attachment 集成-');
    final remote = Directory(p.join(root.path, 'remote 裸.git'));
    final fixture = _Attachments(root, remote);
    await fixture.git([
      'init',
      '--bare',
      '--template=',
      '--initial-branch=main',
      remote.path
    ]);
    fixture.a = await fixture.repo('clone-a', 'a' * 64);
    fixture.b = await fixture.repo('clone-b', 'b' * 64);
    return fixture;
  }

  String ref(String id) => 'refs/heads/attachment/$id';
  Future<GitSync> repo(String name, String device) async {
    final repository = await GitSync.initialize(
        worktree: Directory(p.join(root.path, name)),
        remoteUrl: remote.path,
        deviceId: device);
    repositories.add(repository);
    return repository;
  }

  Future<(String, File)> ciphertext(List<int> bytes) async {
    final id = await sha256Hex(bytes);
    final file = File(p.join(root.path, '$id.bin'));
    await file.writeAsBytes(bytes, flush: true);
    return (id, file);
  }

  Future<String> head(String ref) async =>
      (await git(['--git-dir=${remote.path}', 'rev-parse', ref])).trim();
  Future<String> pin(GitSync repository) => File(p.join(
          repository.worktree.path,
          '.git',
          'zaizuo-sync',
          'attachment_pins.json'))
      .readAsString();

  Future<ProcessResult> rawGit(List<String> arguments) => Process.run(
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
        'GIT_AUTHOR_NAME': 'attachment-test',
        'GIT_AUTHOR_EMAIL': 'test@invalid',
        'GIT_COMMITTER_NAME': 'attachment-test',
        'GIT_COMMITTER_EMAIL': 'test@invalid',
      });

  Future<String> git(List<String> arguments) async {
    final result = await rawGit(arguments);
    if (result.exitCode != 0)
      throw StateError(
          'attachment fixture git ${arguments.first}: ${result.stderr}');
    return result.stdout as String;
  }

  Future<String> publishRaw(String id, Map<String, List<int>> files,
      {String mode = '100644',
      String? gitlink,
      String message = 'malicious attachment fixture'}) async {
    final repo = Directory(p.join(root.path, 'untrusted-${randomId(6)}'));
    await git(['init', '--template=', repo.path]);
    for (final entry in files.entries) {
      final file = File(p.join(repo.path, 'blob'));
      await file.writeAsBytes(entry.value);
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
        '$mode,$blob,${entry.key}'
      ]);
    }
    if (gitlink != null) {
      await git(
          ['-C', repo.path, 'fetch', '--no-tags', '--', remote.path, ref(id)]);
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
    final head =
        (await git(['-C', repo.path, 'commit-tree', tree, '-m', message]))
            .trim();
    await git([
      '-C',
      repo.path,
      'push',
      '--force',
      '--',
      remote.path,
      '$head:${ref(id)}'
    ]);
    return head;
  }

  Future<void> dispose() async {
    for (final store in stores) {
      await store.close();
    }
    for (final repository in repositories) {
      await repository.close();
    }
    final absolute = p.normalize(p.absolute(root.path));
    if (p.isWithin(
            p.normalize(p.absolute(Directory.systemTemp.path)), absolute) &&
        p.basename(absolute).startsWith('zaizuo attachment 集成-')) {
      await root.delete(recursive: true);
    } else {
      throw StateError('refuse unsafe attachment fixture cleanup');
    }
  }
}
