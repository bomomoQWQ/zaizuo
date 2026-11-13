import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';
import 'package:zaizuo_runtime/zaizuo_runtime.dart';

Future<void> main(List<String> args) async {
  try {
    await run(args);
  } catch (error) {
    // Never print arbitrary exception text/stack/argv: they may contain a
    // password, token, command body, or helper/server credential diagnostic.
    final code = error is DomainException
        ? error.code
        : error is GitSyncException
            ? error.code
            : error is RelayLinkException
                ? error.code
                : error.runtimeType;
    stderr.writeln('操作失败：$code。请参阅runtime运行说明；不要上传私密资料目录。');
    exitCode = 1;
  }
}

Future<void> run(List<String> args) async {
  if (args.isEmpty || args.first == 'help' || args.first == '--help') {
    stdout.writeln('''在座（非界面原型）
init <本机资料目录> <账号名> <昵称>
join-init <目录> <账号名> <昵称> <外部manifest JSON文件> <仓库外根指纹>
join-request <目录> [输出JSON文件]
admit <根账户目录> <请求JSON文件> [输出manifest文件]
status <目录>
command <目录> <操作名> <参数JSON文件> [显式加密通道]
send <目录> <会话编号> <文本>
send-file <目录> <会话编号> <本机文件> [MIME]
send-image <目录> <会话编号> <本机图片>
messages <目录> <会话编号> [数量]
download <目录> <本机file_id> <明确输出路径>
sync <目录> [受管同步目录 Git远端]
serve <目录> <机器人编号> [本机端口]
密码仅ZAIZUO_PASSWORD；OneBot令牌ZAIZUO_ONEBOT_TOKEN（至少32字节）。
后台Git：ZAIZUO_GIT_REMOTE、ZAIZUO_GIT_WORKTREE、ZAIZUO_SYNC_INTERVAL_SECONDS（默认30，至少1）。
可选本机中继：ZAIZUO_RELAY_URL（ws://数字环回地址:端口/v1/ws）、ZAIZUO_RELAY_TOKEN。
首次加入必须核验仓库外指纹；本机资料目录绝不能整目录提交Git。
OneBot成功仅表示本机加密日志落盘，不保证对端收到/写盘。''');
    return;
  }
  if (args.length < 2) throw ArgumentError('缺少资料目录');
  final root = Directory(p.absolute(args[1]));
  final password = Platform.environment['ZAIZUO_PASSWORD'];
  if (password == null || password.isEmpty) {
    throw StateError('需设置ZAIZUO_PASSWORD环境变量，不用argv传密码');
  }
  if (args.first == 'init' || args.first == 'join-init') {
    final joining = args.first == 'join-init';
    if (args.length != (joining ? 6 : 4)) throw ArgumentError('初始化参数错误');
    final manifest = joining
        ? CommunityManifest.fromJson(
            jsonObject(await File(args[4]).readAsString()))
        : null;
    await LocalProfile.initialize(root,
        name: args[2],
        displayName: args[3],
        password: password,
        community: manifest,
        pinnedFingerprint: joining ? args[5] : null);
    stdout.writeln(joining
        ? '待入驻本机资料已创建。请导出join-request交给社区根账户；尚不能发布社区消息。'
        : '本机资料已创建。请离线保存恢复材料；此目录不是Git同步目录。');
    return;
  }
  final profile = await LocalProfile.open(root, password);
  if (args.first == 'join-request') {
    if (args.length < 2 || args.length > 3)
      throw ArgumentError('join-request参数错误');
    final text = canonicalJson(await profile.joinRequest());
    if (args.length == 3) {
      await File(args[2]).writeAsString('$text\n', flush: true);
      stdout.writeln('已导出签名加入请求；不包含私钥/口令。');
    } else {
      stdout.writeln(text);
    }
    return;
  }
  final allowed = {
    'status',
    'admit',
    'command',
    'send',
    'send-file',
    'send-image',
    'messages',
    'download',
    'sync',
    'serve'
  };
  if (!allowed.contains(args.first)) throw ArgumentError('未知命令');
  final remote = args.first == 'sync' && args.length == 4
      ? args[3]
      : Platform.environment['ZAIZUO_GIT_REMOTE'];
  final worktree = args.first == 'sync' && args.length == 4
      ? args[2]
      : Platform.environment['ZAIZUO_GIT_WORKTREE'];
  if ((remote == null) != (worktree == null)) {
    throw StateError('Git远端与受管目录必须成对配置');
  }
  final interval = int.tryParse(
      Platform.environment['ZAIZUO_SYNC_INTERVAL_SECONDS'] ?? '30');
  if (interval == null || interval < 1) throw ArgumentError('同步间隔至少1秒');
  final relayText = Platform.environment['ZAIZUO_RELAY_URL'];
  final relayToken = Platform.environment['ZAIZUO_RELAY_TOKEN'];
  final git = remote == null
      ? null
      : await GitSync.initialize(
          worktree: Directory(p.absolute(worktree!)),
          remoteUrl: remote,
          deviceId: profile.device.certificate!.id);
  ZaizuoNode? node;
  try {
    node = await ZaizuoNode.open(
        profile: profile,
        git: git,
        syncInterval: Duration(seconds: interval),
        relayUrl: args.first == 'serve' && relayText != null
            ? Uri.parse(relayText)
            : null,
        relayToken: args.first == 'serve' ? relayToken : null);
    switch (args.first) {
      case 'status':
        if (args.length != 2) throw ArgumentError('status参数错误');
        stdout.writeln(jsonEncode(node.status()));
      case 'admit':
        if (args.length < 3 || args.length > 4)
          throw ArgumentError('admit参数错误');
        if (git != null) await node.syncOnce();
        final next =
            await node.admit(jsonObject(await File(args[2]).readAsString()));
        if (args.length == 4) {
          await File(args[3])
              .writeAsString('${canonicalJson(next.toJson())}\n', flush: true);
        }
        if (git != null) await node.syncOnce();
        stdout.writeln(jsonEncode({
          'revision': next.revision,
          'published': git != null,
          'manifest_hash': await objectHash(next.toJson())
        }));
      case 'command':
        if (args.length < 4 || args.length > 5)
          throw ArgumentError('command参数错误');
        final result = await node.execute(
            operation: args[2],
            params: jsonObject(await File(args[3]).readAsString()),
            conversation: args.length == 5 ? args[4] : null);
        stdout.writeln(jsonEncode(result));
      case 'send':
        if (args.length != 4) throw ArgumentError('send参数错误');
        final result = await node.execute(operation: 'message.send', params: {
          'conversation': args[2],
          'parts': [
            {
              'type': 'text',
              'data': {'text': args[3]}
            }
          ],
        });
        stdout.writeln(jsonEncode(result));
      case 'send-file':
      case 'send-image':
        final image = args.first == 'send-image';
        if (args.length < 4 || args.length > (image ? 4 : 5))
          throw ArgumentError('附件发送参数错误');
        final input = File(p.absolute(args[3]));
        if (await FileSystemEntity.type(input.path, followLinks: false) !=
                FileSystemEntityType.file ||
            await input.length() > node.media.maxMediaBytes)
          throw ArgumentError('只接受本机有界普通文件');
        final handle = await node.media.upload(
            actorId: profile.identity.public.accountId,
            name: p.basename(input.path),
            bytes: await input.readAsBytes(),
            mime: args.length == 5 ? args[4] : 'application/octet-stream',
            purpose: image ? 'image' : 'file');
        final result = await node.execute(operation: 'message.send', params: {
          'conversation': args[2],
          'parts': [
            {
              'type': image ? 'image' : 'file',
              'data': {'file_id': handle['file_id']}
            }
          ]
        });
        if (git != null) await node.syncOnce();
        stdout.writeln(jsonEncode(result));
      case 'messages':
        if (args.length < 3 || args.length > 4) throw ArgumentError('消息查询参数错误');
        if (git != null) await node.syncOnce();
        final actor =
            node.replica.service.actor(profile.identity.public.accountId);
        final records = node.replica.service.messages(
            actor: actor,
            conversationId: args[2],
            limit: args.length == 4 ? int.parse(args[3]) : 50);
        final projected = <Map<String, dynamic>>[];
        for (final record in records)
          projected.add({
            ...record.toJson(),
            'parts':
                await node.media.project(actorId: actor.id, message: record)
          });
        stdout.writeln(jsonEncode({'messages': projected}));
      case 'download':
        if (args.length != 4) throw ArgumentError('附件下载参数错误');
        final result = await node.media
            .get(actorId: profile.identity.public.accountId, fileId: args[2]);
        final output = File(p.absolute(args[3]));
        if (await output.exists()) throw StateError('输出文件已存在，拒绝覆盖');
        // 输出路径由当前用户明确指定，不使用远端name作为路径。
        await output.create(exclusive: true);
        await output.writeAsBytes(base64Decode(result['data'] as String),
            flush: true);
        stdout.writeln(jsonEncode({
          'saved': output.path,
          'name': result['name'],
          'mime': result['mime'],
          'size': result['size']
        }));
      case 'sync':
        if (!(args.length == 2 || args.length == 4) || git == null) {
          throw ArgumentError('sync需配置Git目录和远端');
        }
        stdout.writeln(jsonEncode(await node.syncOnce()));
      case 'serve':
        if (args.length < 3 || args.length > 4)
          throw ArgumentError('serve参数错误');
        final token = Platform.environment['ZAIZUO_ONEBOT_TOKEN'];
        if (token == null) throw StateError('缺少ZAIZUO_ONEBOT_TOKEN');
        final errors = node.errors.listen((code) {
          stderr.writeln('后台操作失败：$code；Git稍后重试，不代表消息已远端落盘。');
        });
        final stop = Completer<void>();
        final signals = <StreamSubscription<ProcessSignal>>[];
        void requestStop(ProcessSignal _) {
          if (!stop.isCompleted) stop.complete();
        }
        signals.add(ProcessSignal.sigint.watch().listen(requestStop));
        if (!Platform.isWindows)
          signals.add(ProcessSignal.sigterm.watch().listen(requestStop));
        try {
          await node.start(
              botId: args[2],
              token: token,
              port: args.length == 4 ? int.parse(args[3]) : 6700);
          stdout
              .writeln('在座OneBot 11/12仅本机监听：127.0.0.1:${node.port}；Ctrl+C停止。');
          await stop.future;
        } finally {
          for (final signal in signals) {
            await signal.cancel();
          }
          await node
              .close(); // wait for started sync/writes before process exits
          await errors.cancel();
        }
    }
  } finally {
    await node?.close();
    await git?.close();
  }
}
