import 'package:flutter_test/flutter_test.dart';
import 'package:zaizuo_mobile_probe/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'embedded developer tool page exposes a return control on desktop',
    (tester) async {
      var closed = false;
      await tester.pumpWidget(MobileProbe(onClose: () => closed = true));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await tester.pumpAndSettle();
      expect(find.text('← 返回在座'), findsOneWidget);
      // The page must not claim an Android environment failure on desktop.
      expect(find.textContaining('非 Android'), findsOneWidget);
      await tester.tap(find.text('← 返回在座'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
