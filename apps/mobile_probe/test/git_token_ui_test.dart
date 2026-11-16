import 'dart:io';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_mobile_probe/client_app.dart';
import 'package:zaizuo_mobile_probe/client_controller.dart';
import 'package:zaizuo_mobile_probe/git_config_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'settings restores username/preferences and forget uses saved scope rather than edited fields',
    (tester) async {
      final root = (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('zgitscope-');
        return Directory(await dir.resolveSymbolicLinks());
      }))!;
      final client = ClientController(
        root,
        parameters: const KdfParameters(memoryKiB: 32, iterations: 1),
      );
      await tester.runAsync(() async {
        await client.create(
          name: 'scopeui',
          displayName: '范围测试',
          password: 'N7!uiTestX8@Only',
        );
        await GitConfigStore(root).save(
          const GitConfig(
            remote: 'https://example.invalid/original.git',
            username: 'alice',
            remember: true,
          ),
        );
      });
      List<Object?>? forgotten;
      await tester.pumpWidget(
        ClientApp(
          root: root,
          controller: client,
          configureGit:
              (_, remote, username, token, remember, useSaved, forget) async {
                if (forget) forgotten = [remote, username, token];
              },
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('设置与同步'));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpAndSettle();
      Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      expect(
        tester.widget<TextField>(field('HTTPS 用户名')).controller!.text,
        'alice',
      );
      expect(
        tester.widget<TextField>(field('Git 远端')).controller!.text,
        'https://example.invalid/original.git',
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, '加密保存在本机'),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, '使用此仓库已保存的令牌'),
            )
            .value,
        isTrue,
      );
      await tester.enterText(
        field('Git 远端'),
        'https://example.invalid/edited.git',
      );
      await tester.ensureVisible(field('HTTPS 用户名'));
      await tester.enterText(field('HTTPS 用户名'), 'bob');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('清除已保存令牌并断开Git'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清除已保存令牌并断开Git'));
      await tester.pumpAndSettle();
      expect(forgotten, [
        'https://example.invalid/original.git',
        'alice',
        null,
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(client.shutdown);
      await tester.runAsync(() => root.delete(recursive: true));
    },
  );
  testWidgets(
    'optional PAT is obscured, opt-in saved, and cleared after configuration',
    (tester) async {
      final root = (await tester.runAsync(
        () async => Directory(
          await (await Directory.systemTemp.createTemp('zaizuo-token-ui-'))
              .resolveSymbolicLinks(),
        ),
      ))!;
      final client = (await tester.runAsync(
        () async => ClientController(
          root,
          parameters: const KdfParameters(memoryKiB: 32, iterations: 1),
        ),
      ))!;
      await tester.runAsync(
        () => client.create(
          name: 'tokenui',
          displayName: '令牌测试',
          password: 'N7!uiTestX8@Only',
        ),
      );
      String? receivedToken;
      bool? saved;
      await tester.pumpWidget(
        ClientApp(
          root: root,
          controller: client,
          configureGit:
              (_, remote, username, token, remember, useSaved, forget) async {
                receivedToken = token;
                saved = remember;
                expect(remote, 'https://example.invalid/chat.git');
                expect(username, 'x-access-token');
              },
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('设置与同步'));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpAndSettle();
      Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      final patField = field('访问令牌 PAT（可选）');
      expect(tester.widget<TextField>(patField).obscureText, isTrue);
      expect(tester.widget<TextField>(patField).enableSuggestions, isFalse);
      expect(
        tester.widget<TextField>(patField).enableIMEPersonalizedLearning,
        isFalse,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, '加密保存在本机'),
            )
            .value,
        isFalse,
      );
      await tester.ensureVisible(field('Git 远端'));
      await tester.enterText(
        field('Git 远端'),
        'https://example.invalid/chat.git',
      );
      await tester.ensureVisible(patField);
      await tester.enterText(patField, 'FixturePAT!DoNotPersist');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('配置 Git'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('配置 Git'));
      await tester.pumpAndSettle();
      expect(receivedToken, 'FixturePAT!DoNotPersist');
      expect(saved, isFalse);
      expect(tester.widget<TextField>(patField).controller!.text, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(client.shutdown);
      await tester.runAsync(() => root.delete(recursive: true));
    },
  );
}
