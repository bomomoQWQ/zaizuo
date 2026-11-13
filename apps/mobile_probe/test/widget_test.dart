import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaizuo_mobile_probe/main.dart';
import 'package:zaizuo_mobile_probe/probe_service.dart';
import 'package:zaizuo_mobile_probe/project_licenses.dart';

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

  test('内置AGPL/NOTICE资产逐字节匹配根原文且保留第三方notices', () async {
    for (final pair in [
      (projectLicenseAsset, '../../LICENSE'),
      (projectNoticeAsset, '../../NOTICE'),
    ]) {
      final bytes = await rootBundle.load(pair.$1);
      expect(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        orderedEquals(await File(pair.$2).readAsBytes()),
      );
    }
    final license = await rootBundle.loadString(projectLicenseAsset);
    final notice = await rootBundle.loadString(projectNoticeAsset);
    expect(license, contains('GNU AFFERO GENERAL PUBLIC LICENSE'));
    expect(license, contains('15. Disclaimer of Warranty.'));
    expect(license, contains('END OF TERMS AND CONDITIONS'));
    expect(notice, contains('SPDX-License-Identifier: AGPL-3.0-only'));
    expect(notice, contains('retain their respective licenses'));
    final upstream = await rootBundle.load('NOTICES.Z');
    expect(upstream.lengthInBytes, greaterThan(0));
    final thirdParty = utf8.decode(
      gzip.decode(
        upstream.buffer.asUint8List(
          upstream.offsetInBytes,
          upstream.lengthInBytes,
        ),
      ),
    );
    expect(thirdParty, contains('cryptography'));
    expect(thirdParty, contains('The Flutter Authors'));
    expect(
      thirdParty,
      contains('Redistribution and use in source and binary forms'),
    );
    expect(
      projectSourceUrl,
      'https://github.com/bomomoQWQ/zaizuo/tree/v0.1.0-media-test3',
    );
  });

  testWidgets('许可入口离线展示完整AGPL和NOTICE及test3源码地址', (tester) async {
    const channel = MethodChannel('zaizuo.mobile_probe/native');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.pumpWidget(const MobileProbe());
    await tester.pumpAndSettle();
    final entry = find.text('关于 / 许可与对应源码');
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.text(projectSourceUrl), findsOneWidget);
    expect(find.textContaining('不提供任何保证'), findsOneWidget);
    expect(find.textContaining('保留各自原始许可'), findsOneWidget);
    for (final pair in [
      ('查看项目 LICENSE（AGPL-3.0-only）', projectLicenseAsset),
      ('查看项目 NOTICE', projectNoticeAsset),
    ]) {
      // rootBundle performs real I/O; do not await it inside FakeAsync.
      final original = await tester.runAsync(
        () => rootBundle.loadString(pair.$2),
      );
      final control = find.text(pair.$1);
      await tester.ensureVisible(control);
      await tester.runAsync(() => tester.tap(control));
      await tester.pumpAndSettle();
      expect(find.text(original!), findsOneWidget);
    }
    expect(find.text('复制对应源码地址（不联网）'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // The license panel remains independent of the unavailable native service.
    expect(find.byType(ProjectLicensePanel), findsOneWidget);
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
