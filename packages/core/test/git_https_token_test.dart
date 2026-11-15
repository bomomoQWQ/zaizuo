import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';

const _url = 'https://example.invalid/team/repo.git';
const _token = 'SENTINEL-not-a-real-token';

void main() {
  late Directory fixture;
  late String spy;
  late Directory root;

  setUpAll(() async {
    fixture = await Directory.systemTemp.createTemp('zaizuo-https-spy-');
    final source = File(p.join(fixture.path, 'spy.dart'));
    await source.writeAsString(r'''
import 'dart:convert';
import 'dart:io';
void main(List<String> args) {
  final root = args[args.indexOf('-C') + 1];
  // Test-only capture: synthetic sentinel credentials, never real secrets.
  File('$root/capture.json').writeAsStringSync(jsonEncode({
    'args': args, 'env': Platform.environment,
  }));
  final error = File('$root/error.txt');
  if (error.existsSync()) {
    stderr.write(error.readAsStringSync());
    exitCode = 128;
  }
}
''');
    spy = p.join(fixture.path, Platform.isWindows ? 'spy.exe' : 'spy');
    final compiled = await Process.run(Platform.resolvedExecutable,
        ['compile', 'exe', source.path, '-o', spy]);
    expect(compiled.exitCode, 0,
        reason: '${compiled.stdout}\n${compiled.stderr}');
  });
  tearDownAll(() async => fixture.delete(recursive: true));
  setUp(() async {
    root = await fixture.createTemp('repo-');
  });
  tearDown(() async => root.delete(recursive: true));

  GitHttpsToken token([String url = _url]) =>
      GitHttpsToken(repoUrl: url, username: 'x-access-token', token: _token);
  Future<GitCliBackend> opened() async {
    final backend = GitCliBackend(executable: spy, credential: token());
    await backend.open(worktreePath: root.path, remoteUrl: _url, create: false);
    return backend;
  }

  Future<Map<String, dynamic>> capture() async =>
      jsonDecode(await File(p.join(root.path, 'capture.json')).readAsString())
          as Map<String, dynamic>;

  test('public credential validates raw URL and redacts all diagnostics', () {
    for (final url in [
      'http://example.invalid/team/repo.git',
      'ssh://example.invalid/team/repo.git',
      '/tmp/repo',
      'https://user:secret@example.invalid/team/repo.git',
      'https://@example.invalid/team/repo.git',
      '$_url?q=secret',
      '$_url#fragment',
      'https://example.invalid/team/../repo.git',
      'https://example.invalid/./repo.git',
      'https://example.invalid/team/%2e%2e/repo.git',
      'https://example.invalid/team\\repo.git',
      '$_url\n',
    ]) {
      expect(() => token(url), throwsArgumentError, reason: url);
    }
    for (final user in ['', 'user:password', 'user\r\n']) {
      expect(() => GitHttpsToken(repoUrl: _url, username: user, token: _token),
          throwsArgumentError);
    }
    expect(token().toString(), 'GitHttpsToken(<redacted>)');
    expect(token('https://EXAMPLE.invalid:443/team/repo.git').repoUrl, _url);
    expect(token('https://example.invalid:8443/team/repo.git').repoUrl,
        'https://example.invalid:8443/team/repo.git');
  });

  test('wrong origin, repository, slash, protocol rejected before any process',
      () async {
    for (final remote in [
      'https://other.invalid/team/repo.git',
      'https://example.invalid/team/other.git',
      'https://example.invalid:8443/team/repo.git',
      '$_url/',
      'ssh://example.invalid/team/repo.git',
      root.path,
    ]) {
      final backend = GitCliBackend(executable: spy, credential: token());
      await expectLater(
          backend.open(
              worktreePath: root.path, remoteUrl: remote, create: true),
          throwsA(isA<GitSyncException>()
              .having((e) => e.code, 'code', 'credential_remote_mismatch')));
      await backend.close();
      expect(await File(p.join(root.path, 'capture.json')).exists(), isFalse);
    }
  });

  test('only network children receive ephemeral header; no helper discovery',
      () async {
    final backend = await opened();
    // Opening explicit mode with create=false must not even query helpers.
    expect(await File(p.join(root.path, 'capture.json')).exists(), isFalse);
    final header =
        'Authorization: Basic ${base64Encode(utf8.encode('x-access-token:$_token'))}';
    for (final action in <Future<void> Function()>[
      () async {
        await backend.advertise('refs/heads/main');
      },
      () => backend.fetch('refs/heads/main:refs/test'),
      () => backend.push('refs/test:refs/heads/main'),
    ]) {
      await action();
      final record = await capture();
      final args = record['args'] as List<dynamic>;
      final env = record['env'] as Map<String, dynamic>;
      expect(args.join(' '), isNot(contains(_token)));
      expect(args.join(' '), isNot(contains(header)));
      expect(args.where((v) => v.toString().startsWith('credential.helper=')),
          ['credential.helper=']);
      expect(env['GIT_CONFIG_COUNT'], '5');
      final config = <String, dynamic>{
        for (var i = 0; i < 5; i++)
          env['GIT_CONFIG_KEY_$i'] as String: env['GIT_CONFIG_VALUE_$i'],
      };
      expect(config['http.extraHeader'], header);
      expect(config['http.followRedirects'], 'false');
      expect(config['http.sslVerify'], 'true');
      expect(config['credential.helper'], '');
      expect(config['credential.useHttpPath'], 'true');
      expect(args, contains(_url));
    }
    await backend.getRef('refs/heads/main');
    final local = await capture();
    expect((local['env'] as Map)['GIT_CONFIG_COUNT'], isNull);
    expect(jsonEncode(local), isNot(contains(_token)));
    expect(jsonEncode(local), isNot(contains(header)));
    expect(await File(p.join(root.path, '.git', 'config')).exists(), isFalse);
    await backend.close();
  });

  test('real Git initialization never persists token or authorization header',
      () async {
    final sync = await GitSync.initializeWithBackend(
      backend: GitCliBackend(credential: token()),
      worktree: root,
      remoteUrl: _url,
      deviceId: 'a' * 64,
    );
    final config =
        await File(p.join(root.path, '.git', 'config')).readAsString();
    expect(config, isNot(contains(_token)));
    expect(config.toLowerCase(), isNot(contains('authorization')));
    expect(config.toLowerCase(), isNot(contains('extraheader')));
    await sync.close();
  });

  test('canonical host/default port bind, full path remains exact', () async {
    final backend = GitCliBackend(executable: spy, credential: token());
    await backend.open(
        worktreePath: root.path,
        remoteUrl: 'https://EXAMPLE.invalid:443/team/repo.git',
        create: false);
    await backend.advertise('refs/heads/main');
    expect((await capture())['args'], contains(_url));
    await backend.close();
  });

  test('failure codes are allowlisted and never return stderr or URL',
      () async {
    final backend = await opened();
    final cases = {
      'HTTP 401 Authentication failed': 'authentication_failed',
      'auth failed': 'authentication_failed',
      'HTTP 403': 'permission_denied',
      'HTTP 404 repository not found': 'repository_unavailable',
      'Could not resolve host': 'network_unavailable',
      'Failed to connect': 'network_unavailable',
      'SSL certificate problem': 'tls_failed',
      'unrecognized error': 'git_failed',
    };
    for (final entry in cases.entries) {
      await File(p.join(root.path, 'error.txt')).writeAsString(
          '${entry.key} $_url $_token Authorization: Basic SECRET');
      await expectLater(
          backend.advertise('refs/heads/main'),
          throwsA(isA<GitSyncException>()
              .having((e) => e.code, 'code', entry.value)
              .having(
                  (e) => e.toString(),
                  'redacted',
                  allOf(isNot(contains(_token)), isNot(contains(_url)),
                      isNot(contains('SECRET'))))));
    }
    await backend.close();
  });

  test('clean environment removes inherited config and closed backend rejects',
      () async {
    final env = GitCliBackend.cleanEnvironment();
    expect(env['GIT_CONFIG_COUNT'], isNull);
    expect(env.keys.where((k) => k.toUpperCase().startsWith('GIT_CONFIG_KEY_')),
        isEmpty);
    expect(
        env.keys.where((k) => k.toUpperCase().startsWith('GIT_CONFIG_VALUE_')),
        isEmpty);
    expect(env['GIT_CONFIG_PARAMETERS'], isNull);
    final backend = await opened();
    await backend.close();
    await expectLater(backend.advertise('refs/heads/main'), throwsStateError);
    expect(await File(p.join(root.path, 'capture.json')).exists(), isFalse);
  });
}
