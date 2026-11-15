import 'dart:io';

import 'package:flutter/material.dart'; // ignore: deprecated_member_use
import 'package:flutter_test/flutter_test.dart';
import 'package:zaizuo_mobile_probe/client_entry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('startup filesystem errors expose a numeric code, not arbitrary exception text', () {
    expect(
      startupFailureCode(
        const FileSystemException('secret', 'private', OSError('private', 5)),
      ),
      'directory_io_5',
    );
    expect(startupFailureCode(StateError('do-not-show')), 'path_state_failure');
  });
  testWidgets(
    'startup failure is recoverable and never auto switches data roots',
    (tester) async {
      await tester.pumpWidget(
        const ClientEntry(dataDirectory: 'relative-not-allowed'),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(find.text('无法打开默认资料目录'), findsOneWidget);
      expect(find.text('重试默认目录'), findsOneWidget);
      if (Platform.isWindows || Platform.isLinux) {
        expect(find.text('使用程序旁的便携资料目录'), findsOneWidget);
      }
      expect(find.byType(FilledButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
