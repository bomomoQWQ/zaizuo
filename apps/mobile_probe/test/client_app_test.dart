import 'dart:io';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_mobile_probe/client_app.dart';
import 'package:zaizuo_mobile_probe/client_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fast = KdfParameters(memoryKiB: 32, iterations: 1, parallelism: 1);
  const password = 'FrontendTest8!Only';

  testWidgets(
    'welcome has real profile controls and never invents chat history',
    (tester) async {
      final root = (await tester.runAsync(() async {
        final temporary = await Directory.systemTemp.createTemp(
          'zaizuo-front-welcome-',
        );
        return Directory(await temporary.resolveSymbolicLinks());
      }))!;
      final controller = ClientController(root, parameters: fast);
      await tester.pumpWidget(ClientApp(root: root, controller: controller));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      });
      await tester.pumpAndSettle();
      expect(find.text('在座'), findsWidgets);
      expect(
        find.text(
          '测试版 · ${const String.fromEnvironment('ZAIZUO_BUILD_LABEL', defaultValue: 'dev')}',
        ),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsWidgets);
      expect(controller.isOpen, isFalse);
      expect(controller.conversations, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(controller.shutdown);
      await tester.runAsync(() => root.delete(recursive: true));
    },
  );

  testWidgets(
    'wide and narrow layouts render actual locally persisted conversation',
    (tester) async {
      final root = (await tester.runAsync(() async {
        final temporary = await Directory.systemTemp.createTemp(
          'zaizuo-front-chat-',
        );
        return Directory(await temporary.resolveSymbolicLinks());
      }))!;
      final controller = ClientController(root, parameters: fast);
      await tester.runAsync(() async {
        await controller.create(
          name: 'fronttest',
          displayName: '前端测试员',
          password: password,
        );
        await controller.createSpace('测试讨论');
        await controller.sendText('真实本机持久化消息');
      });
      expect(controller.error, isNull);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ClientApp(root: root, controller: controller));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      });
      await tester.pumpAndSettle();
      expect(find.text('真实本机持久化消息'), findsOneWidget);
      expect(find.text('前端测试员'), findsWidgets);
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('测试讨论'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(controller.shutdown);
      await tester.runAsync(() => root.delete(recursive: true));
    },
  );
}
