import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:git2dart/git2dart.dart' as git;
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_git_mobile/git_mobile.dart';

void main() {
  test('native HTTPS backend diagnostic (no credentials)', () async {
    final result = await Isolate.run(
      () => [
        git.Libgit2.version,
        git.Libgit2.featureBackend(git.GitFeature.https),
      ],
    );
    // Version/backend contains neither URL nor credentials.
    print('libgit2 diagnostic: $result');
  });

  test('reject transport and origin credentials before native calls', () async {
    for (final url in [
      'http://example.test/repo',
      'ssh://example.test/repo',
      'https://user:pat@example.test/repo',
    ]) {
      final backend = EmbeddedGitBackend(bundledCaPath: 'F:/ca.pem');
      await expectLater(
        backend.open(worktreePath: 'unused', remoteUrl: url, create: true),
        throwsA(isA<GitSyncException>()),
      );
    }
    expect(
      () => GitHttpsCredential(
        repositoryUrl: 'https://example.test/repo',
        username: 'user',
        personalAccessToken: '',
      ),
      throwsA(isA<GitSyncException>()),
    );
  });

  test(
    'raw binary blob writes, header limits, compare-and-set and serialization',
    () async {
      final temp = Directory.systemTemp.createTempSync('zaizuo-primitive-');
      // A test-only bare shape; no network or command-line Git required.
      final remote = Directory('${temp.path}/remote.git')..createSync();
      File('${remote.path}/HEAD').writeAsStringSync('ref: refs/heads/main\n');
      Directory('${remote.path}/objects').createSync();
      final backend = EmbeddedGitBackend.testLocalBare(maxBlobBytes: 8192);
      try {
        await backend.open(
          worktreePath: '${temp.path}/work',
          remoteUrl: remote.path,
          create: true,
        );
        final bytes = Uint8List.fromList([0, 255, 128, 0, 0xe4, 0xb8, 0xad]);
        final sha = await backend.createBlob(bytes);
        expect((await backend.objectInfo(sha)).size, bytes.length);
        expect(await backend.readBlob(sha), bytes);
        final tree = await backend.createTree({'nested/中文.bin': sha});
        final commit = await backend.createCommit(
          tree: tree,
          parents: [],
          message: '中文',
          authorName: 'zaizuo',
          authorEmail: 'test@invalid',
          committerName: 'zaizuo',
          committerEmail: 'test@invalid',
          authorDate: '946684800 +0000',
          committerDate: '946684800 +0000',
        );
        final attempts = await Future.wait(
          List.generate(8, (_) async {
            try {
              await backend.updateRef(
                'refs/heads/main',
                commit,
                expectedOld: '0000000000000000000000000000000000000000',
              );
              return true;
            } on GitSyncException {
              return false;
            }
          }),
        );
        expect(attempts.where((value) => value), hasLength(1));
        expect(await backend.readBlob('$commit:nested/中文.bin'), bytes);
        expect(
          (await backend.listTree(commit, recursive: true)).single.mode,
          '100644',
        );
        await expectLater(
          backend.createBlob(Uint8List(8193)),
          throwsA(isA<GitSyncException>()),
        );
        await expectLater(
          backend.createTree({'../escape': sha}),
          throwsA(isA<GitSyncException>()),
        );
      } finally {
        await backend.close();
        temp.deleteSync(recursive: true);
      }
    },
  );
}
