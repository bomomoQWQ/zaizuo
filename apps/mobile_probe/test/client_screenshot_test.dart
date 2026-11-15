import 'dart:io';
import 'dart:ui' as ui;

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_mobile_probe/client_app.dart';
import 'package:zaizuo_mobile_probe/client_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('capture real controller conversation for visual review', (
    tester,
  ) async {
    final root = (await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp(
        'zaizuo-front-visual-',
      );
      return Directory(await temp.resolveSymbolicLinks());
    }))!;
    if (Platform.isWindows) {
      await tester.runAsync(() async {
        final icons = FontLoader('MaterialIcons');
        icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
        final font = FontLoader('Microsoft YaHei');
        final bytes = await File(r'C:\Windows\Fonts\msyh.ttc').readAsBytes();
        font.addFont(Future.value(bytes.buffer.asByteData()));
        await font.load();
      });
    }
    final client = ClientController(
      root,
      parameters: const KdfParameters(
        memoryKiB: 32,
        iterations: 1,
        parallelism: 1,
      ),
    );
    await tester.runAsync(() async {
      await client.create(
        name: 'uitest',
        displayName: '测试员',
        password: 'VisualTest9!Only',
      );
      await client.createSpace('前端联调');
      await client.sendText('在座测试前端已接入真实本地运行时。');
      await client.sendText('文字会加密持久化。配置 Git 后，可以手动同步到另一台设备。');
    });
    expect(client.error, isNull);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: ClientApp(root: root, controller: client),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = File('../../dist/screenshots/frontend-chat.png');
      await output.parent.create(recursive: true);
      await output.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(client.shutdown);
    await tester.runAsync(() => root.delete(recursive: true));
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
