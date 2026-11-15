import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zaizuo_core/zaizuo_core.dart';

import 'https_fixture.dart';

class _TrustedFixtureGit extends GitCliBackend {
  _TrustedFixtureGit(this.ca, GitHttpsToken credential)
    : super(credential: credential);
  final String ca;
  @override
  Future<void> open({
    required String worktreePath,
    required String remoteUrl,
    required bool create,
  }) async {
    // The test oracle uses a private CA and retains certificate verification.
    // Its local child config is installed after open, not a production option.
    await Directory(worktreePath).create(recursive: true);
    await super.open(
      worktreePath: worktreePath,
      remoteUrl: remoteUrl,
      create: create,
    );
    await Directory(p.join(worktreePath, '.git', 'zaizuo-sync', 'empty-hooks'))
        .create(recursive: true);
    final result = await Process.run('git', [
      '-C',
      worktreePath,
      'config',
      'http.sslCAInfo',
      ca,
    ]);
    expect(result.exitCode, 0);
    if (Platform.isWindows) {
      final result = await Process.run('git', [
        '-C',
        worktreePath,
        'config',
        'http.sslBackend',
        'openssl',
      ]);
      expect(result.exitCode, 0);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('CLI explicit token authenticates real HTTPS push/fetch without URL or config secrets', () async {
    final fixture = await HttpsGitFixture.start();
    addTearDown(fixture.close);
    final remote = fixture.remote.toString();
    final backend = _TrustedFixtureGit(
      fixture.caFile.path,
      GitHttpsToken(
        repoUrl: remote,
        username: HttpsGitFixture.username,
        token: HttpsGitFixture.password,
      ),
    );
    addTearDown(backend.close);
    final work = p.join(fixture.root.path, 'writer');
    await backend.open(worktreePath: work, remoteUrl: remote, create: true);
    final blob = await backend.createBlob(Uint8List.fromList([0, 1, 255, 3]));
    final tree = await backend.createTree({'object.bin': blob});
    final head = await backend.createCommit(
      tree: tree,
      parents: [],
      message: 'token HTTPS fixture',
      authorName: 'zaizuo',
      authorEmail: 'fixture@zaizuo.invalid',
      committerName: 'zaizuo',
      committerEmail: 'fixture@zaizuo.invalid',
    );
    const ref = 'refs/heads/main';
    await backend.updateRef(ref, head, expectedOld: '0' * 40);
    await backend.push('$ref:$ref');
    expect(await backend.advertise(ref), {ref: head});
    final config = await File(p.join(work, '.git', 'config')).readAsString();
    expect(config, isNot(contains(HttpsGitFixture.password)));
    expect(config, isNot(contains('Authorization')));
    final wrong = _TrustedFixtureGit(
      fixture.caFile.path,
      GitHttpsToken(
        repoUrl: remote,
        username: HttpsGitFixture.username,
        token: 'IncorrectFixtureOnly',
      ),
    );
    addTearDown(wrong.close);
    await wrong.open(
      worktreePath: p.join(fixture.root.path, 'wrong'),
      remoteUrl: remote,
      create: true,
    );
    await expectLater(
      wrong.advertise(ref),
      throwsA(
        isA<GitSyncException>().having(
          (e) => e.code,
          'auth code',
          'authentication_failed',
        ),
      ),
    );
    final redirect = _TrustedFixtureGit(
      fixture.caFile.path,
      GitHttpsToken(
        repoUrl: fixture.redirect.toString(),
        username: HttpsGitFixture.username,
        token: HttpsGitFixture.password,
      ),
    );
    addTearDown(redirect.close);
    await redirect.open(
      worktreePath: p.join(fixture.root.path, 'redirect'),
      remoteUrl: fixture.redirect.toString(),
      create: true,
    );
    await expectLater(
      redirect.advertise(ref),
      throwsA(isA<GitSyncException>()),
    );
  });
}
