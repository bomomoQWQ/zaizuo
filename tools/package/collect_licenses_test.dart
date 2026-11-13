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
  final project = Directory('${root.path}/project')..createSync();
  final own = Directory('${project.path}/packages/demo')
    ..createSync(recursive: true);
  final projectLicense = File('${project.path}/LICENSE')
    ..writeAsStringSync('AGPL-3.0-only project license fixture.\n');
  final projectNotice = File('${project.path}/NOTICE')
    ..writeAsStringSync('Original project copyright notice fixture.\n');
  File('${own.path}/LICENSE').writeAsStringSync(
    'Do not use a stale per-package notice instead of the project license.\n',
  );
  // 第三方pathdep即使位于带根LICENSE的祖先下、或名称带zaizuo_前缀，也不能被重许可。
  final pathdeps = Directory('${project.path}/pathdeps')..createSync();
  File('${pathdeps.path}/LICENSE').writeAsStringSync(
    'Unrelated ancestor license, never a package-root license.\n',
  );
  final package = Directory('${pathdeps.path}/sample')..createSync();
  final license = File('${package.path}/LICENSE')
    ..writeAsStringSync('Sample MIT notice retained unchanged.\r\n');
  final lock = File('${project.path}/pubspec.lock')
    ..writeAsStringSync('# test only\n');
  final configDir = Directory('${project.path}/config')..createSync();
  final config = File('${configDir.path}/package_config.json');
  Map<String, String> entry(String name, String rootUri) => {
    'name': name,
    'rootUri': rootUri,
    'packageUri': 'lib/',
  };
  void configure(List<Map<String, String>> packages) {
    config.writeAsStringSync(
      jsonEncode({'configVersion': 2, 'packages': packages}),
    );
  }

  final collector = File.fromUri(
    Platform.script.resolve('collect_licenses.dart'),
  );
  Future<ProcessResult> run(String out, {Directory? projectRoot}) =>
      Process.run(
        Platform.resolvedExecutable,
        [
          collector.path,
          config.path,
          lock.path,
          '${root.path}/$out',
          (projectRoot ?? project).path,
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
  void checkCopy(String output, String relative, File source) {
    final copy = File('${root.path}/$output/$relative');
    if (!copy.existsSync() ||
        base64Encode(copy.readAsBytesSync()) !=
            base64Encode(source.readAsBytesSync())) {
      throw StateError('notice changed or missing: $output/$relative');
    }
  }

  configure([
    entry('sample', '../pathdeps/sample'),
    entry('zaizuo_external', '../pathdeps/sample'),
    entry('zaizuo_demo', '../packages/demo'),
  ]);
  final positive = await run('positive');
  if (positive.exitCode != 0) {
    throw StateError('valid license collection failed: ${positive.stderr}');
  }
  checkCopy('positive', 'sample/LICENSE', license);
  checkCopy('positive', 'zaizuo_external/LICENSE', license);
  checkCopy('positive', 'zaizuo/LICENSE', projectLicense);
  checkCopy('positive', 'zaizuo/NOTICE', projectNotice);
  checkCopy('positive', 'zaizuo_demo/LICENSE', projectLicense);
  checkCopy('positive', 'zaizuo_demo/NOTICE', projectNotice);
  checkCopy('positive', 'dependencies.lock', lock);
  final index = File('${root.path}/positive/INDEX.txt').readAsStringSync();
  if (!index.contains('zaizuo_demo: AGPL-3.0-only') ||
      index.contains('未定') ||
      index.contains('许可证待用户决定') ||
      File('${root.path}/positive/zaizuo_external/NOTICE').existsSync()) {
    throw StateError('owned/third-party license attribution wrong');
  }
  final missingPackage = Directory('${pathdeps.path}/missing')..createSync();
  for (final name in ['missing', 'zaizuo_missing']) {
    configure([entry(name, missingPackage.uri.toString())]);
    final result = await run(name);
    if (result.exitCode != 1 ||
        !(result.stderr as String).contains('缺少第三方许可证：$name')) {
      throw StateError(
        'missing third-party package-root license not rejected: '
        'exit=${result.exitCode} stderr=${result.stderr}',
      );
    }
  }
  // 与packages相似的路径前缀不是owned目录。
  final lookalike = Directory('${project.path}/packages-foreign/demo')
    ..createSync(recursive: true);
  configure([entry('zaizuo_lookalike', lookalike.uri.toString())]);
  if ((await run('lookalike')).exitCode != 1) {
    throw StateError('lookalike owned path accepted');
  }
  configure([entry('../escape', package.uri.toString())]);
  if ((await run('unsafe')).exitCode == 0) {
    throw StateError('unsafe package name accepted');
  }
  configure([
    entry('sample', package.uri.toString()),
    entry('SAMPLE', package.uri.toString()),
  ]);
  if ((await run('duplicate')).exitCode == 0) {
    throw StateError('case-insensitive duplicate package name accepted');
  }
  configure([entry('zaizuo_demo', own.uri.toString())]);
  for (final absent in ['LICENSE', 'NOTICE']) {
    final incomplete = Directory('${root.path}/no-$absent')..createSync();
    Directory('${incomplete.path}/packages').createSync();
    final present = absent == 'LICENSE' ? 'NOTICE' : 'LICENSE';
    File('${incomplete.path}/$present').writeAsStringSync('Fixture only.\n');
    final result = await run('missing-root-$absent', projectRoot: incomplete);
    if (result.exitCode != 1 ||
        !(result.stderr as String).contains('缺少项目根许可/声明：$absent')) {
      throw StateError(
        'missing root $absent not rejected: '
        'exit=${result.exitCode} stderr=${result.stderr}',
      );
    }
  }
  stdout.writeln(
    'collect_licenses: exact third-party bytes / owned AGPL+NOTICE / '
    'pathdep and prefix isolation / missing root and third-party / unsafe / duplicate passed',
  );
}
