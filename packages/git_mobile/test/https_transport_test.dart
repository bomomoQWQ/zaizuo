import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:git2dart/git2dart.dart' as native;
import 'package:path/path.dart' as p;
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_git_mobile/git_mobile.dart';

import 'https_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (native.Libgit2.featureBackend(native.GitFeature.https) != 'openssl') {
    test('unsupported native TLS backend fails closed rather than ignoring bundled CA', () async {
      final backend = EmbeddedGitBackend(
        bundledCaPath: p.absolute('not-used-on-unsupported-backend.pem'),
      );
      addTearDown(backend.close);
      final root = await Directory.systemTemp.createTemp(
        'zaizuo-unsupported-tls-',
      );
      addTearDown(() => root.delete(recursive: true));
      await expectLater(
        backend.open(
          worktreePath: p.join(root.path, 'repo'),
          remoteUrl: 'https://example.invalid/never-contacted.git',
          create: true,
        ),
        throwsA(
          isA<GitSyncException>().having(
            (e) => e.code,
            'fail-closed code',
            'unsupported_tls_backend',
          ),
        ),
      );
    });
    // This platform proves only the negative contract. The four network cases
    // below must additionally run on the pinned OpenSSL Linux/Android build.
    return;
  }
  late HttpsGitFixture fixture;
  final active = <EmbeddedGitBackend>[];
  setUpAll(() async {
    fixture = await HttpsGitFixture.start();
  });
  tearDownAll(() => fixture.close());
  tearDown(() async {
    for (final backend in active.reversed) {
      await backend.close();
    }
    active.clear();
  });

  Future<EmbeddedGitBackend> backend(
    String folder, {
    Uri? remote,
    bool authenticated = true,
    String? token,
    String? ca,
  }) async {
    final uri = remote ?? fixture.remote;
    final result = EmbeddedGitBackend(
      bundledCaPath: ca ?? fixture.caFile.path,
      credential: authenticated
          ? GitHttpsCredential(
              repositoryUrl: uri.toString(),
              username: HttpsGitFixture.username,
              personalAccessToken: token ?? HttpsGitFixture.password,
            )
          : null,
    );
    active.add(result);
    await result.open(
      worktreePath: p.join(fixture.root.path, folder),
      remoteUrl: uri.toString(),
      create: true,
    );
    return result;
  }

  Future<String> commit(
    EmbeddedGitBackend backend,
    List<int> bytes, {
    List<String> parents = const [],
  }) async {
    final blob = await backend.createBlob(Uint8List.fromList(bytes));
    final tree = await backend.createTree({'object.bin': blob});
    return backend.createCommit(
      tree: tree,
      parents: parents,
      message: 'TLS fixture',
      authorName: 'zaizuo',
      authorEmail: 'fixture@zaizuo.invalid',
      committerName: 'zaizuo',
      committerEmail: 'fixture@zaizuo.invalid',
      authorDate: '946684800 +0000',
      committerDate: '946684800 +0000',
    );
  }

  test('native HTTPS authenticates and exchanges exact binary Git objects with CLI oracle', () async {
    final writer = await backend('writer');
    const ref =
        'refs/heads/dev/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final bytes = Uint8List.fromList(List.generate(8192, (i) => i % 256));
    final head = await commit(writer, bytes);
    await writer.updateRef(ref, head, expectedOld: '0' * 40);
    try {
      await writer.push('$ref:$ref');
    } on GitSyncException catch (error) {
      fail(
        'native authenticated HTTPS push failed at push stage: ${error.code}',
      );
    }
    expect(await writer.advertise(ref), {ref: head});
    final reader = await backend('reader');
    const incoming = 'refs/zaizuo-incoming/tls/device';
    await reader.fetch('+$ref:$incoming');
    expect(await reader.getRef(incoming), head);
    expect(await reader.readBlob('$head:object.bin'), bytes);
    final oracle = await Process.run('git', [
      '--git-dir=${fixture.bare.path}',
      'show',
      '$ref:object.bin',
    ], stdoutEncoding: null);
    expect(oracle.exitCode, 0);
    expect(oracle.stdout as List<int>, bytes);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('bad credentials and absent credentials fail without fallback or token leakage', () async {
    final wrong = await backend(
      'wrong-token',
      token: 'NeverPrintThis!WrongToken',
    );
    await expectLater(
      wrong.advertise('refs/heads/main'),
      throwsA(
        isA<GitSyncException>().having(
          (e) => e.toString(),
          'sanitized',
          isNot(contains('NeverPrintThis')),
        ),
      ),
    );
    final anonymous = await backend('anonymous', authenticated: false);
    await expectLater(
      anonymous.advertise('refs/heads/main'),
      throwsA(isA<GitSyncException>()),
    );
  });

  test('TLS trust cannot switch after initialization; wrong hostname and redirects rejected', () async {
    final wrongHost = await backend(
      'wrong-host',
      remote: fixture.wrongHostname,
    );
    await expectLater(
      wrongHost.advertise('refs/heads/main'),
      throwsA(isA<GitSyncException>()),
    );
    await expectLater(
      backend('unknown-ca', ca: fixture.unrelatedCaFile.path),
      throwsA(
        isA<GitSyncException>().having(
          (e) => e.code,
          'immutable worker trust policy',
          'ca_policy_change_required',
        ),
      ),
    );
    final redirect = await backend('redirect', remote: fixture.redirect);
    await expectLater(
      redirect.advertise('refs/heads/main'),
      throwsA(isA<GitSyncException>()),
    );
  });

  test('HTTPS non-fast-forward rejection does not silently report push success', () async {
    const ref =
        'refs/heads/dev/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    final first = await backend('first');
    final head = await commit(first, [1, 2, 3]);
    await first.updateRef(ref, head, expectedOld: '0' * 40);
    await first.push('$ref:$ref');
    final second = await backend('second');
    final fork = await commit(second, [9, 8, 7]);
    await second.updateRef(ref, fork, expectedOld: '0' * 40);
    await expectLater(
      second.push('$ref:$ref'),
      throwsA(isA<GitSyncException>()),
    );
    expect(await first.advertise(ref), {ref: head});
  });
}
