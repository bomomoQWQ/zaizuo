import 'package:flutter_test/flutter_test.dart';
import 'package:git2dart/git2dart.dart' as native;
import 'package:path/path.dart' as p;
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_git_mobile/git_mobile.dart';

import 'https_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('fresh native process with unrelated CA never accepts the fixture certificate', () async {
    final fixture = await HttpsGitFixture.start();
    addTearDown(fixture.close);
    final backend = EmbeddedGitBackend(
      bundledCaPath: fixture.unrelatedCaFile.path,
      credential: GitHttpsCredential(
        repositoryUrl: fixture.remote.toString(),
        username: HttpsGitFixture.username,
        personalAccessToken: HttpsGitFixture.password,
      ),
    );
    addTearDown(backend.close);
    if (native.Libgit2.featureBackend(native.GitFeature.https) != 'openssl') {
      await expectLater(
        backend.open(
          worktreePath: p.join(fixture.root.path, 'untrusted'),
          remoteUrl: fixture.remote.toString(),
          create: true,
        ),
        throwsA(
          isA<GitSyncException>().having(
            (e) => e.code,
            'fail-closed',
            'unsupported_tls_backend',
          ),
        ),
      );
      return;
    }
    await backend.open(
      worktreePath: p.join(fixture.root.path, 'untrusted'),
      remoteUrl: fixture.remote.toString(),
      create: true,
    );
    await expectLater(
      backend.advertise('refs/heads/main'),
      throwsA(isA<GitSyncException>()),
    );
  });
}
