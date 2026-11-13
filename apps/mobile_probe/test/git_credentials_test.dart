import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zaizuo_mobile_probe/git_credential_panel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaizuo_mobile_probe/git_credentials.dart';

Widget _credentialTestBuilder(BuildContext context, Widget? child) =>
    const Directionality(
      textDirection: TextDirection.ltr,
      child: DefaultTextStyle(style: TextStyle(), child: GitCredentialPanel()),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('zaizuo.mobile_probe/native');
  const store = AndroidGitCredentialStore();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  testWidgets('PAT input is obscured and cleared after explicit save', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    await tester.pumpWidget(
      WidgetsApp(
        color: Color(0xffffffff),
        builder: _credentialTestBuilder,
      ),
    );
    final fields = find.byType(EditableText);
    expect(fields, findsNWidgets(3));
    expect(tester.widget<EditableText>(fields.at(2)).obscureText, isTrue);
    await tester.enterText(fields.at(0), 'https://example.test/repo');
    await tester.enterText(fields.at(1), 'alice');
    await tester.enterText(fields.at(2), 'fake-test-token');
    await tester.tap(find.text('保存此仓库测试凭据'));
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(fields.at(2)).controller.text, isEmpty);
    expect(find.textContaining('不代表 Git 同步已通过'), findsOneWidget);
  });

  test('requires explicit complete HTTPS repo without URL credentials', () {
    for (final url in [
      'http://example.test/repo.git',
      'ssh://example.test/repo.git',
      'git@example.test:repo.git',
      'https://user:pat@example.test/repo.git',
      'https://@example.test/repo.git',
      'https://example.test/repo?token=x',
      'https://example.test/repo#fragment',
      'https://example.test/',
      'https://example.test/a/../repo',
      'https://example.test/%2e%2e/repo',
    ]) {
      expect(
        () => GitCredentialScope(url, 'alice'),
        throwsA(isA<GitCredentialException>()),
      );
    }
    expect(
      GitCredentialScope(
        'HTTPS://EXAMPLE.TEST:443/a/repo.git',
        'alice',
      ).repoUrl,
      'https://example.test/a/repo.git',
    );
    expect(
      () => GitCredentialScope('https://example.test/repo', ''),
      throwsA(isA<GitCredentialException>()),
    );
  });

  test(
    'save/read/delete forward exact repo and username, no host fallback',
    () async {
      final encryptedStoreFake = <String, String>{};
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        final args = Map<String, Object>.from(call.arguments as Map);
        final key = '${args['repoUrl']}\n${args['username']}';
        switch (call.method) {
          case 'gitCredentialSave':
            encryptedStoreFake[key] = args['token'] as String;
          case 'gitCredentialRead':
            if (!encryptedStoreFake.containsKey(key)) {
              throw PlatformException(code: 'credential_missing');
            }
            return encryptedStoreFake[key];
          case 'gitCredentialDelete':
            encryptedStoreFake.remove(key);
        }
        return null;
      });
      final scope = GitCredentialScope(
        'https://example.test/a/repo.git',
        'alice',
      );
      await store.save(scope, 'fake-test-token');
      expect(await store.read(scope), 'fake-test-token');
      for (final other in [
        GitCredentialScope('https://example.test/b/repo.git', 'alice'),
        GitCredentialScope(scope.repoUrl, 'bob'),
        GitCredentialScope('https://other.test/a/repo.git', 'alice'),
      ]) {
        await expectLater(
          store.read(other),
          throwsA(
            isA<GitCredentialException>().having(
              (e) => e.code,
              'code',
              'credential_missing',
            ),
          ),
        );
      }
      await store.delete(scope);
      await store.delete(scope);
      await expectLater(
        store.read(scope),
        throwsA(isA<GitCredentialException>()),
      );
      expect(
        methods,
        containsAll([
          'gitCredentialSave',
          'gitCredentialRead',
          'gitCredentialDelete',
        ]),
      );
    },
  );

  test(
    'fixed error codes discard potentially sensitive exception messages',
    () async {
      final scope = GitCredentialScope('https://example.test/repo', 'alice');
      for (final code in [
        'credential_corrupt',
        'credential_invalidated',
        'credential_missing',
        'unexpected-secret',
      ]) {
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => throw PlatformException(
            code: code,
            message: 'fake-sensitive-token',
            details: 'private-path',
          ),
        );
        try {
          await store.read(scope);
          fail('read must fail');
        } on GitCredentialException catch (error) {
          expect(
            error.code,
            code == 'unexpected-secret' ? 'credential_unavailable' : code,
          );
          expect(error.toString(), isNot(contains('fake-sensitive-token')));
          expect(error.toString(), isNot(contains('private-path')));
        }
      }
    },
  );

  test(
    'invalid PAT rejected before native call; null read is corruption',
    () async {
      final scope = GitCredentialScope('https://example.test/repo', 'alice');
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return null;
      });
      for (final token in ['', 'bad\npat', 'bad\u0000pat']) {
        await expectLater(
          store.save(scope, token),
          throwsA(isA<GitCredentialException>()),
        );
      }
      expect(calls, 0);
      await expectLater(
        store.read(scope),
        throwsA(
          isA<GitCredentialException>().having(
            (e) => e.code,
            'code',
            'credential_corrupt',
          ),
        ),
      );
      expect(scope.toString(), isNot(contains('example.test')));
    },
  );
}
