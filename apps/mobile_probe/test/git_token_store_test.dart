import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zaizuo_mobile_probe/git_token_store.dart';

const _repo = 'https://example.invalid/team/repo.git';
const _username = 'ephemeral-test-user';
const _token = 'ephemeral-test-token-not-a-real-secret';

Matcher _code(String code) =>
    isA<GitTokenStoreException>().having((e) => e.code, 'fixed code', code);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late Directory root;
  late GitTokenStore store;

  setUp(() async {
    // Only ephemeral test-owned data; never inspect profile/host credentials.
    temporary = await Directory.systemTemp.createTemp('zaizuo-token-test-');
    temporary = Directory(await temporary.resolveSymbolicLinks());
    root = Directory(p.join(temporary.path, 'credentials'));
    store = GitTokenStore(root);
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  Future<void> save([String token = _token]) =>
      store.save(repositoryUrl: _repo, username: _username, token: token);
  Future<String?> read() =>
      store.read(repositoryUrl: _repo, username: _username);
  Future<void> remove() =>
      store.delete(repositoryUrl: _repo, username: _username);
  Future<File> storedFile() async =>
      (await root.list().toList()).whereType<File>().single;

  test('scope validation precedes platform and filesystem access', () async {
    for (final url in [
      'https://example.invalid/a/../repo',
      'https://example.invalid/a/./repo',
      'https://example.invalid/%2e%2e/repo',
      'https://example.invalid/repo?token=fake',
      'https://example.invalid/repo#fragment',
      'https://user:fake@example.invalid/repo',
      'https://example.invalid/repo\n',
      'ssh://example.invalid/repo',
    ]) {
      await expectLater(
        store.read(repositoryUrl: url, username: _username),
        throwsA(_code('credential_invalid_scope')),
      );
    }
    for (final name in ['', 'a:b', 'line\nbreak', 'nul\u0000name']) {
      await expectLater(
        store.read(repositoryUrl: _repo, username: name),
        throwsA(_code('credential_invalid_scope')),
      );
    }
    expect(await root.exists(), isFalse);
    expect(store.toString(), 'GitTokenStore(redacted)');
    expect(
      const GitTokenStoreException('credential_unavailable').toString(),
      'GitTokenStoreException(credential_unavailable)',
    );
  });

  test(
    'token limit is UTF-8 bytes, rejects controls and malformed Unicode',
    () async {
      for (final token in [
        '',
        'line\nbreak',
        'bad\u007ftoken',
        'bad\u0000token',
        List.filled(8193, 'é').join(),
        String.fromCharCode(0xd800),
      ]) {
        await expectLater(
          save(token),
          throwsA(_code('credential_invalid_input')),
        );
      }
      expect(await root.exists(), isFalse);
    },
  );

  test('unsupported platforms never create plaintext fallback', () async {
    await expectLater(save(), throwsA(_code('credential_unsupported')));
    await expectLater(read(), throwsA(_code('credential_unsupported')));
    await expectLater(remove(), throwsA(_code('credential_unsupported')));
    expect(await root.exists(), isFalse);
  }, skip: Platform.isWindows || Platform.isAndroid);

  group('Windows real CurrentUser DPAPI', () {
    test('missing is null; real roundtrip, canonical URL, atomic overwrite and delete', () async {
      expect(await read(), isNull);
      await remove();
      await save();
      expect(await read(), _token);
      expect(
        await store.read(
          repositoryUrl: 'HTTPS://EXAMPLE.INVALID:443/team/repo.git',
          username: _username,
        ),
        _token,
      );
      final file = await storedFile();
      expect(p.basename(file.path), matches(RegExp(r'^[a-f0-9]{64}\.json$')));
      final data = await file.readAsBytes();
      expect(utf8.decode(data), isNot(contains(_token)));
      expect(
        utf8.decode(data),
        isNot(contains(base64Encode(utf8.encode(_token)))),
      );
      final value = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      expect(value.keys.toSet(), {'version', 'repo', 'username', 'ciphertext'});
      expect(value['version'], 1);
      expect(value['repo'], _repo);
      expect(value['username'], _username);
      final encrypted = base64Decode(value['ciphertext'] as String);
      expect(encrypted, isNot(utf8.encode(_token)));
      await save('replacement-ephemeral-token');
      expect(await read(), 'replacement-ephemeral-token');
      expect((await root.list().toList()).length, 1);
      await remove();
      await remove();
      expect(await read(), isNull);
      expect(await root.list().toList(), isEmpty);
    });

    test('exact byte boundary survives DPAPI', () async {
      final token = List.filled(8192, 'é').join();
      await save(token);
      expect(await read(), token);
    });

    test('wrong scope fails closed even with matching JSON metadata', () async {
      await save();
      final first = await storedFile();
      final original =
          jsonDecode(await first.readAsString()) as Map<String, dynamic>;
      for (final other in [
        (repo: 'https://example.invalid/team/other.git', user: _username),
        (repo: _repo, user: 'another-ephemeral-user'),
        (repo: 'https://other.invalid/team/repo.git', user: _username),
      ]) {
        expect(
          await store.read(repositoryUrl: other.repo, username: other.user),
          isNull,
        );
        await store.save(
          repositoryUrl: other.repo,
          username: other.user,
          token: 'other-fake',
        );
        final second = (await root.list().toList())
            .whereType<File>()
            .singleWhere((file) => file.path != first.path);
        await second.writeAsString(
          jsonEncode({...original, 'repo': other.repo, 'username': other.user}),
        );
        await expectLater(
          store.read(repositoryUrl: other.repo, username: other.user),
          throwsA(_code('credential_unavailable')),
        );
        await store.delete(repositoryUrl: other.repo, username: other.user);
        expect(await read(), _token);
      }
    });

    test(
      'malformed, oversized, metadata mismatch and corrupt DPAPI fail closed',
      () async {
        await save();
        final file = await storedFile();
        final original =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        for (final value in <Object?>[
          null,
          [],
          {},
          {...original, 'version': 2},
          {...original, 'repo': 'https://example.invalid/other.git'},
          {...original, 'username': 'other'},
          {...original, 'ciphertext': 'not base64!'},
          {
            ...original,
            'ciphertext': base64Encode([1, 2, 3]),
          },
          {...original, 'ciphertext': ''},
          {...original, 'extra': true},
        ]) {
          await file.writeAsString(jsonEncode(value));
          await expectLater(read(), throwsA(_code('credential_unavailable')));
        }
        await file.writeAsString('{broken');
        await expectLater(read(), throwsA(_code('credential_unavailable')));
        await file.writeAsBytes(List.filled(96 * 1024 + 1, 65));
        await expectLater(read(), throwsA(_code('credential_unavailable')));
      },
    );

    test('directory target rejected without deleting old content', () async {
      await save();
      final file = await storedFile();
      final targetPath = file.path;
      await file.delete();
      final target = await Directory(targetPath).create();
      final sentinel = File(p.join(target.path, 'sentinel'));
      await sentinel.writeAsString('test-owned-sentinel');
      await expectLater(save(), throwsA(_code('credential_unavailable')));
      await expectLater(read(), throwsA(_code('credential_unavailable')));
      await expectLater(remove(), throwsA(_code('credential_unavailable')));
      expect(await sentinel.readAsString(), 'test-owned-sentinel');
      expect((await root.list().toList()).length, 1);
    });

    test('file and ancestor symlinks rejected without following', () async {
      // Creating Windows symlinks can require a privilege not present in the
      // test account. Never request UAC or change machine policy for this test.
      final target = await Directory(p.join(temporary.path, 'link-target'))
          .create();
      final link = Link(p.join(temporary.path, 'linked-parent'));
      try {
        await link.create(target.path);
      } on FileSystemException {
        return;
      }
      final linkedStore = GitTokenStore(
        Directory(p.join(link.path, 'credentials')),
      );
      await expectLater(
        linkedStore.save(
          repositoryUrl: _repo,
          username: _username,
          token: _token,
        ),
        throwsA(_code('credential_unavailable')),
      );
      expect(await target.list().toList(), isEmpty);
      await link.delete();
      await save();
      final file = await storedFile();
      final backing = File(p.join(temporary.path, 'unrelated'));
      await backing.writeAsString('test-owned-sentinel');
      await file.delete();
      final fileLink = await Link(file.path).create(backing.path);
      await expectLater(read(), throwsA(_code('credential_unavailable')));
      await expectLater(save(), throwsA(_code('credential_unavailable')));
      await expectLater(remove(), throwsA(_code('credential_unavailable')));
      expect(await backing.readAsString(), 'test-owned-sentinel');
      await fileLink.delete();
    });
  }, skip: !Platform.isWindows);
}
