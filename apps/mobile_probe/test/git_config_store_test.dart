import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zaizuo_mobile_probe/git_config_store.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('zaizuo-gitcfg-');
  });
  tearDown(() async => root.delete(recursive: true));

  test('saved binding round-trips without any secret material', () async {
    final store = GitConfigStore(root);
    await store.save(
      const GitConfig(
        remote: 'https://github.com/bomomoQWQ/zaizuotest',
        username: 'bomomoQWQ',
        remember: true,
      ),
    );
    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.remote, 'https://github.com/bomomoQWQ/zaizuotest');
    expect(loaded.username, 'bomomoQWQ');
    expect(loaded.remember, isTrue);
    final text = await File('${root.path}/git-config.json').readAsString();
    expect(text, isNot(contains('github_pat_')));
    expect(text.toLowerCase(), isNot(contains('token')));
    expect(text.toLowerCase(), isNot(contains('password')));
    expect(loaded.toString(), isNot(contains('bomomoQWQ/zaizuotest')));
    await store.clear();
    expect(await store.load(), isNull);
  });

  test(
    'damaged or hostile values are ignored instead of blocking unlock',
    () async {
      final file = File('${root.path}/git-config.json');
      for (final text in [
        'not json',
        '{"version":2,"remote":"https://x.test/r","username":"u","remember":true}',
        '{"version":1,"remote":"javascript:alert(1)","username":"u","remember":true}',
        '{"version":1,"remote":"https://x.test/r","username":"u","remember":"yes"}',
        '{"version":1,"remote":"https://x.test/r\\u0000","username":"u","remember":true}',
      ]) {
        await file.writeAsString(text);
        expect(await GitConfigStore(root).load(), isNull, reason: text);
      }
      await file.writeAsString('x' * 9000);
      expect(await GitConfigStore(root).load(), isNull);
      expect(file.path, endsWith('git-config.json'));
    },
  );
}
