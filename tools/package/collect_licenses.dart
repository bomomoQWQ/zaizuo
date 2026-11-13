// 仅构建时运行。按 package_config 的精确包根收集 LICENSE，不读取任何用户资料。
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  if (args.length != 3) {
    stderr.writeln(
      'usage: dart collect_licenses.dart <package_config.json> <pubspec.lock> <output-dir>',
    );
    exitCode = 64;
    return;
  }
  final configFile = File(args[0]).absolute;
  final config =
      jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
  final output = Directory(args[2]).absolute;
  output.createSync(recursive: true);
  final index = <String>[];
  final missing = <String>[];
  final packages = (config['packages'] as List).cast<Map<String, dynamic>>()
    ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  for (final package in packages) {
    final name = package['name'] as String;
    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(name)) {
      throw const FormatException('unsafe package name');
    }
    final packageRoot = configFile.uri.resolve(package['rootUri'] as String);
    final root = Directory.fromUri(packageRoot);
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
      if (name.startsWith('zaizuo_')) {
        index.add('$name: 本项目许可证待用户决定，不擅自附加开源许可。');
      } else {
        missing.add(name);
      }
      continue;
    }
    final dest = Directory('${output.path}/$name')..createSync();
    for (final source in files) {
      final basename = source.uri.pathSegments.last;
      File('${dest.path}/$basename')
          .writeAsBytesSync(source.readAsBytesSync(), flush: true);
    }
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
