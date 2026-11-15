import 'dart:io';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_mobile_probe/client_app.dart';
import 'package:zaizuo_mobile_probe/client_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('无头用户流程：错误密码校验、创建账号、建空间、发消息、锁定解锁', (tester) async {
    final root = (await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'zaizuo-user-flow-',
      );
      return Directory(await directory.resolveSymbolicLinks());
    }))!;
    final client = (await tester.runAsync(
      () async => ClientController(
        root,
        parameters: const KdfParameters(memoryKiB: 32, iterations: 1),
      ),
    ))!;
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ClientApp(root: root, controller: client));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
    await tester.pumpAndSettle();
    Future<void> fill(String label, String value) async {
      final field = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, value);
    }

    Future<void> click(String title) async {
      final button = find.text(title).last;
      await tester.ensureVisible(button);
      await tester.runAsync(() async {
        await tester.tap(button);
        await Future<void>.delayed(const Duration(milliseconds: 700));
      });
      await tester.pumpAndSettle();
    }

    await fill('账户名', 'bbtest');
    await fill('显示名称', '无头测试员');
    await fill('密码', '123456789012');
    await fill('确认密码', '123456789012');
    await click('创建并进入');
    expect(find.textContaining('[invalid_password]'), findsOneWidget);
    expect(client.isOpen, isFalse);
    await fill('密码', 'M8!vR2@kL9#sT6%z');
    await fill('确认密码', 'M8!vR2@kL9#sT6%z');
    await click('创建并进入');
    expect(client.error, isNull);
    expect(client.isOpen, isTrue);
    await tester.tap(find.text('新建空间').first);
    await tester.pumpAndSettle();
    await fill('空间名称', '黑盒流程测试');
    await click('创建');
    expect(client.selectedConversation, isNotNull);
    final composer = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == '写一条消息…',
    );
    await tester.enterText(composer, '从界面按钮写入的真实消息');
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('发送'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(find.text('从界面按钮写入的真实消息'), findsOneWidget);
    expect(client.messages, hasLength(1));
    // Persistence and unlock use the same public controller API as the buttons;
    // no host mouse/keyboard or window automation is involved.
    final selected = client.selectedConversationId!;
    await tester.runAsync(client.lock);
    await tester.pumpAndSettle();
    expect(client.isOpen, isFalse);
    await tester.runAsync(() => client.unlock('M8!vR2@kL9#sT6%z'));
    client.selectConversation(selected);
    await tester.pumpAndSettle();
    expect(find.text('从界面按钮写入的真实消息'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(client.shutdown);
    await tester.runAsync(() => root.delete(recursive: true));
  });
}
