import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaizuo_mobile_probe/main.dart';
import 'package:zaizuo_mobile_probe/probe_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('验证壳明确显示未完成能力，不伪称IM/Git可用', (tester) async {
    const channel = MethodChannel('zaizuo.mobile_probe/native');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => {
            'privateRoot':
                '${Directory.systemTemp.path}/widget-probe-not-created',
            'sdk': 34,
            'abi': 'test-only',
          },
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.pumpWidget(const MobileProbe());
    await tester.pumpAndSettle();
    expect(find.text('在座 · Android 验证壳'), findsOneWidget);
    expect(find.textContaining('非完整 IM'), findsOneWidget);
    expect(find.textContaining('未配置 Git'), findsOneWidget);
    expect(find.textContaining('内置 PNG'), findsOneWidget);
  });

  test('实际fixture纯Dart WebP压缩+密文落盘+解密往返且可重新打开测试profile', () async {
    final root = await Directory.systemTemp.createTemp(
      'zaizuo-mobile-probe-test-',
    );
    addTearDown(() => root.delete(recursive: true));
    // Native tools use an ASCII workspace alias; attachment roots must resolve
    // to their actual app-private filesystem path, not a junction ancestor.
    final dataRoot = Directory(await root.resolveSymbolicLinks());
    final probe = ProbeService(dataRoot);
    await probe.initialize();
    final input = await File('assets/probe.png').readAsBytes();
    final result = await probe.roundTrip(input);
    expect(result.inputBytes, input.length);
    expect(result.width, 64);
    expect(result.height, 48);
    expect(result.webpBytes, greaterThan(0));
    expect(result.cipherHash, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(
      await File('${root.path}/cipher-objects/${result.cipherHash}.bin')
          .exists(),
      isTrue,
    );
    final reopened = ProbeService(dataRoot);
    await reopened.initialize();
    final second = await reopened.roundTrip(input);
    expect(second.preview, result.preview);
    expect(second.cipherHash, isNot(result.cipherHash));
  });

  test('未初始化和超上限输入不伪报往返成功', () async {
    final root = await Directory.systemTemp.createTemp(
      'zaizuo-mobile-probe-limits-',
    );
    addTearDown(() => root.delete(recursive: true));
    // Native tools use an ASCII workspace alias; attachment roots must resolve
    // to their actual app-private filesystem path, not a junction ancestor.
    final dataRoot = Directory(await root.resolveSymbolicLinks());
    final probe = ProbeService(dataRoot);
    await expectLater(probe.roundTrip([1]), throwsStateError);
    await probe.initialize();
    await expectLater(probe.roundTrip([]), throwsStateError);
    await expectLater(
      probe.roundTrip(List<int>.filled(probeMaxBytes + 1, 0)),
      throwsStateError,
    );
    await expectLater(probe.roundTrip([1, 2, 3]), throwsFormatException);
  });
}
