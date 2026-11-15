import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';
import 'package:zaizuo_mobile_probe/client_controller.dart';

/// The UI must never collapse an unexpected failure into an unlabelled generic
/// error: each category keeps a stable code so a report is actionable.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ClientController client;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zaizuo-error-map-');
    client = ClientController(
      root,
      parameters: const KdfParameters(memoryKiB: 32, iterations: 1),
    );
    await client.create(
      name: 'errormap',
      displayName: '错误映射',
      password: 'E7!rrorMapX9@Ok',
    );
  });

  tearDown(() async {
    await client.shutdown();
    await root.delete(recursive: true);
  });

  test('unmapped failures keep the code and expose only the type', () async {
    final future = client.queueForTest(() async => throw _Boom());
    await expectLater(future, throwsA(isA<DomainException>()));
    expect(client.error, contains('[operation_failed]'));
    expect(client.error, contains('(_Boom)'));
    // No message content leaks into the user-visible text.
    expect(client.error, isNot(contains('secret detail')));
  });

  test('state, timeout and argument failures get their own codes', () async {
    await expectLater(
      client.queueForTest<void>(() async => throw StateError('x')),
      throwsA(isA<DomainException>()),
    );
    expect(client.error, contains('[state_error]'));
    await expectLater(
      client.queueForTest<void>(() async => throw TimeoutException('slow')),
      throwsA(isA<DomainException>()),
    );
    expect(client.error, contains('[timeout]'));
    await expectLater(
      client.queueForTest<void>(() async => throw const FormatException()),
      throwsA(isA<DomainException>()),
    );
    expect(client.error, contains('[invalid_argument]'));
  });

  test('unknown git codes still collapse to the generic label', () async {
    await expectLater(
      client.queueForTest<void>(
        () async => throw const GitSyncException('mystery', 'x'),
      ),
      throwsA(isA<DomainException>()),
    );
    expect(client.error, contains('[operation_failed]'));
  });
}

class _Boom implements Exception {
  @override
  String toString() => 'secret detail should not be shown';
}
