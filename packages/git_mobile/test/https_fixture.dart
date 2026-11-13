import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Real loopback TLS smart Git server. Only this oracle starts system Git.
class HttpsGitFixture {
  HttpsGitFixture._(this.root, this.bare, this.server, this.port, this.caFile);
  final Directory root;
  final Directory bare;
  final Process server;
  final int port;
  final File caFile;
  File get unrelatedCaFile => File(p.join(root.path, 'unrelated-ca.pem'));
  static const username = 'fixture-user';
  static const password = 'FixtureOnly!NativeGit8#';
  Uri get remote => Uri.parse('https://localhost:$port/remote.git');
  Uri get wrongHostname => Uri.parse('https://127.0.0.1:$port/remote.git');
  Uri get redirect => Uri.parse('https://localhost:$port/redirect.git');

  static Future<HttpsGitFixture> start() async {
    final temporary = await Directory.systemTemp.createTemp(
      'zaizuo-native-https-',
    );
    final root = Directory(await temporary.resolveSymbolicLinks());
    // Windows OpenSSL uses narrow native file arguments; preserve the approved
    // ASCII alias for the CA argument only. Files and cleanup use the real root.
    final caArgumentRoot = Platform.isWindows
        ? temporary.absolute.path.replaceFirst(
            r'F:\test靶场\zaizuo',
            r'F:\zaizuo-mobile-probe',
          )
        : temporary.absolute.path;
    final bare = Directory(p.join(root.path, 'remote.git'));
    final repository = Directory.current.parent.parent;
    final openssl = Platform.isWindows
        ? r'C:\Program Files\Git\mingw64\bin\openssl.exe'
        : 'openssl';
    final python = Platform.isWindows ? r'C:\Python313\python.exe' : 'python3';
    Future<void> run(String executable, List<String> args) async {
      final result = await Process.run(
        executable,
        args,
        workingDirectory: root.path,
      );
      if (result.exitCode != 0) {
        throw StateError(
          'TLS fixture setup failed: ${p.basename(executable)} (${result.exitCode})',
        );
      }
    }

    try {
      await run('git', ['init', '--bare', '--initial-branch=main', bare.path]);
      await run(openssl, [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-sha256',
        '-days',
        '1',
        '-subj',
        '/CN=Zaizuo Fixture CA',
        '-keyout',
        'ca.key',
        '-out',
        'ca.pem',
        '-addext',
        'basicConstraints=critical,CA:TRUE',
      ]);
      await run(openssl, [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-sha256',
        '-days',
        '1',
        '-subj',
        '/CN=Unrelated Fixture CA',
        '-keyout',
        'unrelated-ca.key',
        '-out',
        'unrelated-ca.pem',
        '-addext',
        'basicConstraints=critical,CA:TRUE',
      ]);
      await run(openssl, [
        'req',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-sha256',
        '-subj',
        '/CN=localhost',
        '-keyout',
        'server.key',
        '-out',
        'server.csr',
      ]);
      await File(p.join(root.path, 'server.ext')).writeAsString(
        'subjectAltName=DNS:localhost\nbasicConstraints=critical,CA:FALSE\n'
        'keyUsage=critical,digitalSignature,keyEncipherment\n'
        'extendedKeyUsage=serverAuth\n',
      );
      await run(openssl, [
        'x509',
        '-req',
        '-in',
        'server.csr',
        '-CA',
        'ca.pem',
        '-CAkey',
        'ca.key',
        '-CAcreateserial',
        '-days',
        '1',
        '-sha256',
        '-extfile',
        'server.ext',
        '-out',
        'server.pem',
      ]);
      final git = Platform.isWindows
          ? r'C:\Program Files\Git\cmd\git.exe'
          : 'git';
      final server = await Process.start(
        python,
        [
          p.join(repository.path, 'tools', 'mobile_git_https', 'server.py'),
          '--root',
          root.path,
          '--cert',
          p.join(root.path, 'server.pem'),
          '--key',
          p.join(root.path, 'server.key'),
          '--git',
          git,
        ],
        environment: {
          'ZAIZUO_FIXTURE_USER': username,
          'ZAIZUO_FIXTURE_TOKEN': password,
          'PYTHONDONTWRITEBYTECODE': '1',
        },
      );
      unawaited(server.stderr.drain<void>());
      final ready = await server.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 20));
      final state = jsonDecode(ready) as Map;
      if (state['ready'] != true || state['port'] is! int) {
        server.kill();
        await server.exitCode;
        throw StateError('TLS fixture failed to become ready');
      }
      return HttpsGitFixture._(
        root,
        bare,
        server,
        state['port'] as int,
        File(p.join(caArgumentRoot, 'ca.pem')),
      );
    } catch (_) {
      await _removeRoot(root);
      rethrow;
    }
  }

  Future<void> close() async {
    server.kill();
    await server.exitCode.timeout(const Duration(seconds: 10));
    await _removeRoot(root);
  }

  static Future<void> _removeRoot(Directory root) async {
    final base = await Directory.systemTemp.resolveSymbolicLinks();
    if (!p.isWithin(base, root.path) ||
        !p.basename(root.path).startsWith('zaizuo-native-https-')) {
      throw StateError('unexpected TLS fixture cleanup path');
    }
    if (await root.exists()) await root.delete(recursive: true);
  }
}
