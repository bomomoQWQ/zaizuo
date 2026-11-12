import 'dart:async';
import 'dart:io';

import 'package:zaizuo_relay/zaizuo_relay.dart';

/// 仅演示宿主如何启动/停止模块；不是部署工具，也不会替宿主配置 TLS。
/// Flutter Native 可以在宿主生命周期内保留 server 并 await server.close()。
Future<void> main() async {
  final token = Platform.environment['ZAIZUO_RELAY_TOKEN'];
  if (token == null) {
    stderr.writeln('请通过 ZAIZUO_RELAY_TOKEN 提供 32–256 字符测试连接令牌。');
    exitCode = 64;
    return;
  }
  final RelayConfig config;
  try {
    config = RelayConfig(token: token);
  } on ArgumentError {
    stderr.writeln('连接令牌配置无效（不会回显令牌）。');
    exitCode = 64;
    return;
  }
  final server = await RelayServer.start(config);
  // 只展示监听端口。包本身不打印凭据、请求、payload 或连接日志。
  stdout.writeln('在座中继演示监听 127.0.0.1:${server.port}；按 Enter 停止。');
  final stopped = Completer<void>();
  final input = stdin.listen((_) {
    if (!stopped.isCompleted) stopped.complete();
  }, onDone: () {
    if (!stopped.isCompleted) stopped.complete();
  });
  try {
    await stopped.future;
  } finally {
    await input.cancel();
    await server.close();
  }
}
