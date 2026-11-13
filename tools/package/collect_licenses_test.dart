// 无测试框架依赖的打包工具自测；临时文件在显式传入的.local目录，不处理用户资料。
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln(
      'usage: dart collect_licenses_test.dart <empty-local-test-root>',
    );
    exitCode = 64;
    return;
  }
  final root = Directory(args.single).absolute;
  if (root.existsSync()) throw StateError('测试目录已存在，拒绝覆盖');
  root.createSync(recursive: true);
  final package = Directory('${root.path}/sample')..createSync();
  final license = File('${package.path}/LICENSE');
  license.writeAsStringSync('Sample MIT notice retained unchanged.\n');
  final lock = File('${root.path}/pubspec.lock')
    ..writeAsStringSync('# test only\n');
  final config = File('${root.path}/package_config.json')
    ..writeAsStringSync(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'sample',
            'rootUri': package.uri.toString(),
            'packageUri': 'lib/',
          },
          {
            'name': 'zaizuo_demo',
            'rootUri': package.parent.uri.resolve('own/').toString(),
            'packageUri': 'lib/',
          },
        ],
      }),
    );
  final collector = File.fromUri(
    Platform.script.resolve('collect_licenses.dart'),
  );
  Future<int> run(String out) async => (await Process.run(
    Platform.resolvedExecutable,
    [collector.path, config.path, lock.path, '${root.path}/$out'],
  )).exitCode;
  if (await run('positive') != 0)
    throw StateError('valid license collection failed');
  final copy = File('${root.path}/positive/sample/LICENSE').readAsStringSync();
  if (copy != license.readAsStringSync()) throw StateError('notice changed');
  if (!File('${root.path}/positive/INDEX.txt')
      .readAsStringSync()
      .contains('许可证待用户决定'))
    throw StateError('own license assumed');
  final missingPackage = Directory('${root.path}/missing-package')
    ..createSync();
  config.writeAsStringSync(
    jsonEncode({
      'configVersion': 2,
      'packages': [
        {
          'name': 'missing',
          'rootUri': missingPackage.uri.toString(),
          'packageUri': 'lib/',
        },
      ],
    }),
  );
  if (await run('missing') != 1)
    throw StateError('missing third-party license not rejected');
  config.writeAsStringSync(
    jsonEncode({
      'configVersion': 2,
      'packages': [
        {
          'name': '../escape',
          'rootUri': package.uri.toString(),
          'packageUri': 'lib/',
        },
      ],
    }),
  );
  if (await run('unsafe') == 0)
    throw StateError('unsafe package name accepted');
  stdout.writeln('collect_licenses: positive / missing / unsafe cases passed');
}
