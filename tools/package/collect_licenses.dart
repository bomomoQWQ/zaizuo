// 仅构建时运行。按 package_config 的精确包根收集 LICENSE，不读取任何用户资料。
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  if (args.length != 3 && args.length != 4) {
    stderr.writeln(
      'usage: dart collect_licenses.dart <package_config.json> <pubspec.lock> <output-dir> [project-root]',
    );
    exitCode = 64;
    return;
  }
  final configFile = File(args[0]).absolute;
  final config =
      jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
  // 不从依赖包的祖先搜索根许可；fixture/其他源码副本必须明确传自己的根目录。
  final projectRoot = args.length == 4
      ? Directory(args[3]).absolute
      : Directory.fromUri(Platform.script.resolve('../../'));
  final projectNotices = [
    File.fromUri(projectRoot.uri.resolve('LICENSE')),
    File.fromUri(projectRoot.uri.resolve('NOTICE')),
  ];
  final missingProjectNotices = projectNotices
      .where((file) => !file.existsSync() || file.lengthSync() == 0)
      .map((file) => file.uri.pathSegments.last)
      .toList();
  if (missingProjectNotices.isNotEmpty) {
    stderr.writeln(
      '缺少项目根许可/声明：${missingProjectNotices.join(', ')}。停止打包，不使用第三方或祖先目录的许可替代。',
    );
    exitCode = 1;
    return;
  }
  final ownedRoot = Directory.fromUri(projectRoot.uri.resolve('packages/'));
  final ownedPrefix =
      ownedRoot.resolveSymbolicLinksSync() + Platform.pathSeparator;
  bool isOwned(String name, Directory root) {
    if (!name.startsWith('zaizuo_') || !root.existsSync()) return false;
    final path = root.resolveSymbolicLinksSync();
    // canonical路径和分隔符边界防止相似前缀、../与符号链接把外部pathdep误当项目代码。
    return Platform.isWindows
        ? path.toLowerCase().startsWith(ownedPrefix.toLowerCase())
        : path.startsWith(ownedPrefix);
  }

  final output = Directory(args[2]).absolute;
  output.createSync(recursive: true);
  final index = <String>['项目原创代码：AGPL-3.0-only；zaizuo/LICENSE, zaizuo/NOTICE。'];
  final missing = <String>[];
  void copyNotices(String name, List<File> files) {
    final dest = Directory('${output.path}/$name')..createSync();
    for (final source in files) {
      final basename = source.uri.pathSegments.last;
      File('${dest.path}/$basename')
          .writeAsBytesSync(source.readAsBytesSync(), flush: true);
    }
  }

  copyNotices('zaizuo', projectNotices);
  final seen = <String>{'zaizuo'}; // 与项目许可目录重名也拒绝，避免覆盖。
  final packages = (config['packages'] as List).cast<Map<String, dynamic>>()
    ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  for (final package in packages) {
    final name = package['name'] as String;
    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(name) ||
        !seen.add(name.toLowerCase())) {
      throw const FormatException('unsafe or duplicate package name');
    }
    final packageRoot = configFile.uri.resolve(package['rootUri'] as String);
    final root = Directory.fromUri(packageRoot);
    if (isOwned(name, root)) {
      copyNotices(name, projectNotices);
      index.add('$name: AGPL-3.0-only（项目根 LICENSE, NOTICE 的逐字副本）');
      continue;
    }
    final candidates = [
      'LICENSE',
      'LICENSE.md',
      'LICENSE.txt',
      'COPYING',
      'COPYING.md',
      'COPYING.txt',
    ];
    final files = candidates
        .map((path) => File.fromUri(root.uri.resolve(path)))
        .where((file) => file.existsSync())
        .toList();
    if (files.isEmpty) {
      missing.add(name);
      continue;
    }
    copyNotices(name, files);
    index.add('$name: ${files.map((f) => f.uri.pathSegments.last).join(', ')}');
  }
  File('${output.path}/INDEX.txt')
      .writeAsStringSync('${index.join('\n')}\n', flush: true);
  File('${output.path}/dependencies.lock')
      .writeAsBytesSync(File(args[1]).readAsBytesSync(), flush: true);
  if (missing.isNotEmpty) {
    stderr.writeln('缺少第三方许可证：${missing.join(', ')}。停止打包，不能静默遗漏。');
    exitCode = 1;
  }
}
