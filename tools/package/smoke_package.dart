// 对已解压测试包执行init/status/文件与图片本机往返，不碰源码或真实账号。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      'usage: dart smoke_package.dart <package-directory> <new-local-test-root>',
    );
    exitCode = 64;
    return;
  }
  final bundle = Directory(args[0]).absolute;
  final root = Directory(args[1]).absolute;
  if (root.existsSync()) throw StateError('smoke目录已存在，拒绝覆盖');
  root.createSync(recursive: true);
  final snapshot = File('${bundle.path}/bin/zaizuo.aot');
  final executable = Platform.isWindows
      ? (snapshot.existsSync()
            ? '${bundle.path}/bin/dartaotruntime.exe'
            : '${bundle.path}/bin/zaizuo.exe')
      : '${bundle.path}/bin/zaizuo';
  final prefix = snapshot.existsSync() ? [snapshot.path] : <String>[];
  final profile = '${root.path}/profile';
  // 假测试秘密只传子进程，不写包/文件/日志，不使用真实账号令牌。
  final environment = Map<String, String>.from(Platform.environment)
    ..remove('ZAIZUO_GIT_REMOTE')
    ..remove('ZAIZUO_GIT_WORKTREE')
    ..remove('ZAIZUO_RELAY_URL')
    ..remove('ZAIZUO_RELAY_TOKEN')
    ..['ZAIZUO_PASSWORD'] = 'Y8!vN2@kR9#pT4%x';
  Future<ProcessResult> invoke(List<String> command) async {
    final result = await Process.run(executable, [
      ...prefix,
      ...command,
    ], environment: environment);
    if (result.exitCode != 0)
      throw StateError(
        'packaged CLI step failed: ${command.first} exit ${result.exitCode}',
      );
    return result;
  }

  await invoke(['--help']);
  await invoke(['init', profile, 'package_media', '打包媒体']);
  await invoke(['status', profile]);
  final params = File('${root.path}/space.json')
    ..writeAsStringSync(
      jsonEncode({'id': 'smoke', 'title': 'smoke', 'public_channel': true}),
    );
  await invoke(['command', profile, 'space.create', params.path]);
  final file = File('${root.path}/input.bin')
    ..writeAsBytesSync(Uint8List.fromList(List.generate(1024, (i) => i % 251)));
  // 固定1x1透明PNG：只作真实默认codec运行验证，不是画质/性能安全证明。
  final png = File('${root.path}/input.png')
    ..writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
  await invoke([
    'send-file',
    profile,
    'smoke#main',
    file.path,
    'application/octet-stream',
  ]);
  await invoke(['send-image', profile, 'smoke#main', png.path]);
  final messages = jsonDecode(
    (await invoke(['messages', profile, 'smoke#main'])).stdout as String,
  ) as Map<String, dynamic>;
  final records = messages['messages'] as List;
  if (records.length != 2) throw StateError('unexpected message count');
  String handle(String type) {
    for (final record in records) {
      for (final part in (record as Map)['parts'] as List) {
        if ((part as Map)['type'] == type)
          return (part['data'] as Map)['file_id'] as String;
      }
    }
    throw StateError('missing $type handle');
  }

  final outFile = File('${root.path}/download.bin');
  final outImage = File('${root.path}/download.webp');
  await invoke(['download', profile, handle('file'), outFile.path]);
  await invoke(['download', profile, handle('image'), outImage.path]);
  if (base64Encode(outFile.readAsBytesSync()) !=
      base64Encode(file.readAsBytesSync()))
    throw StateError('binary bytes changed');
  final image = outImage.readAsBytesSync();
  if (image.length < 12 ||
      ascii.decode(image.sublist(0, 4)) != 'RIFF' ||
      ascii.decode(image.sublist(8, 12)) != 'WEBP')
    throw StateError('not actual WebP');
  await invoke(['status', profile]);
  stdout.writeln(
    'packaged CLI init/status/file roundtrip/default image WebP/download/reopen passed',
  );
}
