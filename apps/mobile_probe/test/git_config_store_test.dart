import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zaizuo_mobile_probe/git_config_store.dart';

void main() {
  late Directory root;
  const config = GitConfig(
    remote: 'https://example.test/team/repository.git',
    username: 'display-user',
    remember: true,
  );
  File binding(Directory dir) => File(p.join(dir.path, 'git-config.json'));
  String encoded(String remote) => jsonEncode({
    'version': 1,
    'remote': remote,
    'username': 'display-user',
    'remember': true,
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zaizuo-gitcfg-');
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'missing, corrupt and cleared bindings have distinct presence',
    () async {
      final store = GitConfigStore(root);
      expect(await store.exists(), isFalse);
      expect(await store.load(), isNull);
      await store.clear();
      await binding(root).writeAsString('broken');
      expect(await store.exists(), isTrue);
      expect(await store.load(), isNull);
      await store.clear();
      expect(await store.exists(), isFalse);
    },
  );

  test('overwrite round-trips only the non-secret fields', () async {
    final store = GitConfigStore(root);
    await store.save(config);
    await store.save(
      const GitConfig(
        remote: 'ssh://git@example.test/team/other.git',
        username: 'another-user',
        remember: false,
      ),
    );
    final loaded = (await store.load())!;
    expect(loaded.remote, 'ssh://git@example.test/team/other.git');
    expect(loaded.username, 'another-user');
    expect(loaded.remember, isFalse);
    expect(await store.exists(), isTrue);
    final value = jsonDecode(await binding(root).readAsString()) as Map;
    expect(
      value.keys,
      unorderedEquals(['version', 'remote', 'username', 'remember']),
    );
    expect(loaded.toString(), isNot(contains('example.test')));
    expect(loaded.toString(), isNot(contains('another-user')));
    expect(await root.list().length, 1);
    await store.clear();
    expect(await store.load(), isNull);
  });

  test('absolute local paths and safe SSH identities are preserved', () async {
    final store = GitConfigStore(root);
    for (final remote in [
      '/tmp/local repository.git',
      r'C:\local repository\repo.git',
      'D:/local/repo.git',
      'https://example.test:443/team/repo.git',
      'ssh://example.test/team/repo.git',
      'ssh://git-user_2@example.test:2222/team/repo.git',
      'ssh://git@[::1]:2222/team/repo.git',
    ]) {
      await store.save(
        GitConfig(remote: remote, username: '', remember: false),
      );
      expect((await store.load())!.remote, remote);
    }
  });

  test('save and load share strict credential-free URL validation', () async {
    final store = GitConfigStore(root);
    final invalid = [
      '',
      'relative/repo.git',
      'http://example.test/repo',
      'file:///tmp/repo',
      'https://user@example.test/repo',
      'https://:secret@example.test/repo',
      'https://user:secret@example.test/repo',
      'https://@example.test/repo',
      'https://example.test/repo?token=secret',
      'https://example.test/repo#secret',
      'https://example.test/repo?',
      'https://example.test/repo#',
      'https://example.test/a/../repo',
      'https://example.test/./repo',
      'https://example.test/%2e%2e/repo',
      'https://example.test/repo%3ftoken=secret',
      r'https://example.test\@other.test/repo',
      'https:///repo',
      'https://example.test:0/repo',
      'https://example.test:65536/repo',
      'https://example.test:abc/repo',
      'https://example.test/repo name',
      ' https://example.test/repo',
      'https://example.test/repo\n',
      'ssh://git:secret@example.test/repo',
      'ssh://-option@example.test/repo',
      'ssh://git;command@example.test/repo',
      'ssh://git@@example.test/repo',
      'ssh://git%40name@example.test/repo',
      'ssh://git@example.test/repo?secret',
      'ssh://git@example.test/a/../repo',
      'ssh://git@example.test/repo#secret',
    ];
    for (var i = 0; i < invalid.length; i++) {
      final remote = invalid[i];
      await expectLater(
        store.save(GitConfig(remote: remote, username: 'u', remember: false)),
        throwsA(
          isA<FormatException>().having(
            (error) => error.toString(),
            'fixed diagnostic',
            'FormatException: invalid_git_binding',
          ),
        ),
        reason: 'invalid fixture $i',
      );
      await binding(root).writeAsString(encoded(remote));
      expect(await store.load(), isNull, reason: 'invalid fixture $i');
    }
  });

  test(
    'corrupt, oversized and unexpected secret fields load as null',
    () async {
      final store = GitConfigStore(root);
      for (final text in [
        'not json',
        '[]',
        '{"version":2,"remote":"https://example.test/r","username":"u","remember":true}',
        '{"version":1,"remote":"https://example.test/r","username":"u","remember":"yes"}',
        '{"version":1,"remote":"https://example.test/r","username":"u\\u0000","remember":true}',
        '{"version":1,"remote":"https://example.test/r","username":"u","remember":true,"token":"synthetic-secret"}',
        'x' * 8193,
        '${encoded(config.remote)}${' ' * 8192}',
      ]) {
        await binding(root).writeAsString(text);
        expect(await store.exists(), isTrue);
        expect(await store.load(), isNull);
      }
      await binding(root).writeAsBytes([0xff, 0xfe]);
      expect(await store.load(), isNull);
    },
  );

  test(
    'unowned old temporary file is never read, overwritten or removed',
    () async {
      final sentinel = File(p.join(root.path, 'git-config.json.tmp'));
      await sentinel.writeAsString('sentinel');
      final store = GitConfigStore(root);
      await store.save(config);
      await store.save(config);
      await store.clear();
      expect(await sentinel.readAsString(), 'sentinel');
      expect(await root.list().length, 1);
    },
  );

  Future<bool> createLink(Link link, String target) async {
    try {
      await link.create(target);
      return true;
    } on FileSystemException {
      // Windows may require Developer Mode or SeCreateSymbolicLinkPrivilege.
      // Report explicitly rather than accidentally testing a regular file.
      markTestSkipped('OS does not permit symbolic link creation');
      return false;
    }
  }

  test(
    'config link: load/save/clear leave sentinel target untouched',
    () async {
      final target = File(p.join(root.path, 'sentinel.json'));
      final contents = encoded(config.remote);
      await target.writeAsString(contents);
      final link = Link(binding(root).path);
      if (!await createLink(link, target.path)) return;
      try {
        final store = GitConfigStore(root);
        expect(await store.exists(), isTrue);
        expect(await store.load(), isNull);
        await expectLater(
          store.save(config),
          throwsA(isA<FileSystemException>()),
        );
        await expectLater(store.clear(), throwsA(isA<FileSystemException>()));
        expect(await target.readAsString(), contents);
        expect(
          await FileSystemEntity.type(link.path, followLinks: false),
          FileSystemEntityType.link,
        );
      } finally {
        await link.delete();
      }
    },
  );

  test(
    'root and ancestor links: load/save/clear do not traverse target',
    () async {
      final target = await Directory(p.join(root.path, 'sentinel')).create();
      final nested = await Directory(p.join(target.path, 'nested')).create();
      final contents = encoded(config.remote);
      await binding(target).writeAsString(contents);
      await binding(nested).writeAsString(contents);
      final link = Link(p.join(root.path, 'linked-root'));
      if (!await createLink(link, target.path)) return;
      try {
        for (final path in [
          link.path,
          p.join(link.path, 'nested'),
          p.join(link.path, 'missing'),
        ]) {
          final store = GitConfigStore(Directory(path));
          expect(await store.load(), isNull);
          await expectLater(
            store.save(config),
            throwsA(isA<FileSystemException>()),
          );
          await expectLater(store.clear(), throwsA(isA<FileSystemException>()));
        }
        expect(await binding(target).readAsString(), contents);
        expect(await binding(nested).readAsString(), contents);
        expect(
          await Directory(p.join(target.path, 'missing')).exists(),
          isFalse,
        );
        expect(await target.list().length, 2);
      } finally {
        await link.delete();
      }
    },
  );

  test('IO failures report fixed diagnostics without input or path', () async {
    await Directory(binding(root).path).create();
    final store = GitConfigStore(root);
    await expectLater(
      store.save(config),
      throwsA(
        isA<FileSystemException>().having(
          (error) => error.toString(),
          'fixed diagnostic',
          "FileSystemException: git_binding_write_failed, path = ''",
        ),
      ),
    );
    await expectLater(
      store.clear(),
      throwsA(
        isA<FileSystemException>().having(
          (error) => error.toString(),
          'fixed diagnostic',
          "FileSystemException: git_binding_clear_failed, path = ''",
        ),
      ),
    );
    expect(await store.load(), isNull);
    expect(await store.exists(), isTrue);
  });
}
