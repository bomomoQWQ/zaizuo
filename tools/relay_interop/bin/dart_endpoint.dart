import 'dart:async';
import 'dart:io';

import 'package:zaizuo_relay/zaizuo_relay.dart';

// This child is intentionally silent. The parent discovers readiness only via
// bounded loopback GET /healthz and always terminates/joins it in finally.
Future<void> main(List<String> args) async {
  final token = Platform.environment['ZAIZUO_RELAY_TOKEN'];
  final port = args.length == 1 ? int.tryParse(args.single) : null;
  if (token == null || port == null || port <= 0 || port > 65535) {
    exitCode = 64;
    return;
  }
  try {
    final server = await RelayServer.start(
      RelayConfig(token: token),
      address: InternetAddress.loopbackIPv4,
      port: port,
    );
    final stopped = Completer<void>();
    final signals = <StreamSubscription<ProcessSignal>>[];
    // Dart's Windows VM reports unsupported SIGTERM asynchronously. Do not
    // subscribe to it there; Process.kill still terminates the test child.
    final supportedSignals = [
      ProcessSignal.sigint,
      if (!Platform.isWindows) ProcessSignal.sigterm,
    ];
    for (final signal in supportedSignals) {
      try {
        signals.add(signal.watch().listen((_) {
          if (!stopped.isCompleted) stopped.complete();
        }, onError: (Object _, StackTrace __) {
          // Process cleanup belongs to the parent's bounded kill/join path.
        }));
      } on SignalException {
        // A platform without process signal streams is still killable by parent.
      }
    }
    try {
      await stopped.future;
    } finally {
      await server.close();
      for (final subscription in signals) {
        await subscription.cancel();
      }
    }
  } catch (_) {
    // Do not echo token, path, body, arbitrary arguments or network errors.
    stderr.writeln('Dart test endpoint failed.');
    exitCode = 1;
  }
}
