import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'https_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('test-server oracle serves authenticated Git HTTPS without disabling TLS', () async {
    final fixture = await HttpsGitFixture.start();
    addTearDown(fixture.close);
    final auth = base64Encode(
      utf8.encode('${HttpsGitFixture.username}:${HttpsGitFixture.password}'),
    );
    final process = await Process.run(
      'git',
      [
        '-c',
        'credential.helper=',
        '-c',
        'http.sslVerify=true',
        if (Platform.isWindows) ...['-c', 'http.sslBackend=openssl'],
        '-c',
        'http.sslCAInfo=${fixture.caFile.path}',
        '-c',
        'http.extraHeader=Authorization: Basic $auth',
        'ls-remote',
        fixture.remote.toString(),
      ],
      environment: {'GIT_TERMINAL_PROMPT': '0'},
    );
    final diagnostic = (process.stderr as String)
        .replaceAll(auth, '<fixture-auth>')
        .replaceAll(HttpsGitFixture.password, '<fixture-token>');
    expect(
      process.exitCode,
      0,
      reason:
          'loopback TLS smart Git fixture must work with CLI oracle: $diagnostic',
    );
  });
}
