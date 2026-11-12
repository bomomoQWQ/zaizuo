import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:zaizuo_core/zaizuo_core.dart';

// A tiny RIFF/WEBP container fixture, NOT a decoded/encoded image. These tests
// verify the wrapper's lifecycle and byte limits; no real cwebp runs here.
const _webp = <int>[82, 73, 70, 70, 4, 0, 0, 0, 87, 69, 66, 80];
const _guard = Duration(seconds: 3);

typedef _Launch = Future<EncoderProcessHandle> Function(
    String executable, List<String> arguments);

final class _Runner implements TrustedEncoderProcessRunner {
  _Runner(this.launch);
  final _Launch launch;
  int starts = 0;
  @override
  Future<EncoderProcessHandle> start(
      String executable, List<String> arguments) {
    starts++;
    return launch(executable, arguments);
  }
}

final class _Process implements EncoderProcessHandle {
  _Process({this.closeOnKill = true}) {
    output = StreamController<List<int>>(
        sync: true, onCancel: () => stdoutCancels++);
    errors = StreamController<List<int>>(
        sync: true, onCancel: () => stderrCancels++);
  }
  final bool closeOnKill;
  late final StreamController<List<int>> output;
  late final StreamController<List<int>> errors;
  final completion = Completer<int>();
  int kills = 0;
  int stdoutCancels = 0;
  int stderrCancels = 0;
  final killed = Completer<void>();
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  Future<int> get exitCode => completion.future;
  @override
  bool kill() {
    kills++;
    if (!killed.isCompleted) killed.complete();
    if (!completion.isCompleted) completion.complete(-1);
    if (closeOnKill) {
      if (!output.isClosed) unawaited(output.close());
      if (!errors.isClosed) unawaited(errors.close());
    }
    return true;
  }

  void exit(int code, {bool closePipes = true}) {
    if (!completion.isCompleted) completion.complete(code);
    if (closePipes) {
      unawaited(output.close());
      unawaited(errors.close());
    }
  }
}

final class _StuckCancelStream extends Stream<List<int>> {
  _StuckCancelStream(this.cancelled);
  final void Function() cancelled;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    return _StuckSubscription(cancelled);
  }
}

final class _StuckSubscription implements StreamSubscription<List<int>> {
  _StuckSubscription(this.cancelled);
  final void Function() cancelled;
  @override
  Future<void> cancel() {
    cancelled();
    return Completer<void>().future;
  }

  @override
  void onData(void Function(List<int>)? handleData) {}
  @override
  void onError(Function? handleError) {}
  @override
  void onDone(void Function()? handleDone) {}
  @override
  void pause([Future<void>? resumeSignal]) {}
  @override
  void resume() {}
  @override
  bool get isPaused => false;
  @override
  Future<E> asFuture<E>([E? futureValue]) => Completer<E>().future;
}

final class _UncooperativeProcess implements EncoderProcessHandle {
  int kills = 0;
  int cancellations = 0;
  final completion = Completer<int>();
  @override
  Stream<List<int>> get stdout => _StuckCancelStream(() => cancellations++);
  @override
  Stream<List<int>> get stderr => _StuckCancelStream(() => cancellations++);
  @override
  Future<int> get exitCode => completion.future;
  @override
  bool kill() {
    kills++;
    return false;
  }
}

File _output(List<String> arguments) =>
    File(arguments[arguments.indexOf('-o') + 1]);
File _snapshot(List<String> arguments) =>
    File(arguments[arguments.indexOf('-o') - 1]);

void main() {
  late Directory root;
  late File input;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('zaizuo-webp-test-');
    input = await File(p.join(root.path, 'source image.png'))
        .writeAsBytes([1, 2, 3, 4]);
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  CWebpEncoder encoder(TrustedEncoderProcessRunner runner,
          {Duration timeout = const Duration(seconds: 2),
          Duration cleanup = const Duration(milliseconds: 200),
          int maxInput = 1024,
          int maxOutput = 1024,
          int maxDiagnostic = 1024}) =>
      CWebpEncoder(
          executable: Platform.resolvedExecutable,
          trustedProcessRunner: runner,
          timeout: timeout,
          cleanupTimeout: cleanup,
          maxInputBytes: maxInput,
          maxOutputBytes: maxOutput,
          maxDiagnosticBytes: maxDiagnostic);

  test('拒绝非绝对本机程序与无效总期限/字节配置', () {
    expect(() => CWebpEncoder(executable: 'cwebp'), throwsArgumentError);
    expect(() => CWebpEncoder(executable: p.join(root.path, 'missing')),
        throwsArgumentError);
    for (final constructor in <CWebpEncoder Function()>[
      () => CWebpEncoder(
          executable: Platform.resolvedExecutable, maxInputBytes: 0),
      () => CWebpEncoder(
          executable: Platform.resolvedExecutable, maxOutputBytes: 0),
      () => CWebpEncoder(
          executable: Platform.resolvedExecutable, maxDiagnosticBytes: 0),
      () => CWebpEncoder(
          executable: Platform.resolvedExecutable,
          timeout: const Duration(seconds: 1),
          cleanupTimeout: const Duration(seconds: 1)),
      () => CWebpEncoder(
          executable: Platform.resolvedExecutable,
          cleanupTimeout: Duration.zero),
    ]) {
      expect(constructor, throwsArgumentError);
    }
  });

  test('cwebp只读私有有界副本，原路径后改不影响副本且回收临时目录', () async {
    late String tempPath;
    final process = _Process();
    final runner = _Runner((executable, arguments) async {
      expect(executable, Platform.resolvedExecutable);
      expect(
          arguments, containsAllInOrder(['-quiet', '-lossless', '-q', '85']));
      final snapshot = _snapshot(arguments);
      expect(snapshot.absolute.path, isNot(input.absolute.path));
      tempPath = snapshot.parent.path;
      expect(await snapshot.readAsBytes(), [1, 2, 3, 4]);
      await input.writeAsBytes([99]);
      expect(await snapshot.readAsBytes(), [1, 2, 3, 4]);
      await _output(arguments).writeAsBytes(_webp);
      process.exit(0);
      return process;
    });
    expect(await encoder(runner).encode(input), _webp);
    expect(await Directory(tempPath).exists(), isFalse);
    expect(process.kills, 0);
    expect(process.stdoutCancels, 1);
    expect(process.stderrCancels, 1);
  });

  test('空/超上限输入在启动前拒绝', () async {
    final runner = _Runner((_, __) async => throw StateError('must not start'));
    await expectLater(
        encoder(runner, maxInput: 3).encode(input), throwsStateError);
    await input.writeAsBytes([]);
    await expectLater(encoder(runner).encode(input), throwsStateError);
    expect(runner.starts, 0);
  });

  test('拒绝symlink路径（平台允许创建时）', () async {
    final link = Link(p.join(root.path, 'linked.png'));
    try {
      await link.create(input.path);
    } on FileSystemException {
      // Windows without symlink privileges cannot construct this fixture.
      markTestSkipped('本机不允许创建符号链接，未验证此OS分支');
      return;
    }
    final runner = _Runner((_, __) async => throw StateError('must not start'));
    await expectLater(
        encoder(runner).encode(File(link.path)), throwsStateError);
    expect(runner.starts, 0);
  });

  test('非零退出/缺失输出/伪输出/过大输出都拒绝且不回显管道', () async {
    for (final scenario in ['nonzero', 'missing', 'invalid', 'oversize']) {
      final process = _Process();
      final runner = _Runner((_, arguments) async {
        if (scenario == 'invalid') {
          await _output(arguments).writeAsBytes([1, 2, 3]);
        } else if (scenario == 'oversize') {
          await _output(arguments).writeAsBytes(List<int>.filled(1025, 1));
        }
        process.errors.add('not-for-log-secret'.codeUnits);
        process.exit(scenario == 'nonzero' ? 2 : 0);
        return process;
      });
      await expectLater(
          encoder(runner).encode(input),
          throwsA(isA<StateError>().having((e) => e.toString(), 'safe error',
              isNot(contains('not-for-log-secret')))));
      expect(process.kills, 0, reason: '已经退出不再按旧PID发送kill');
      expect(process.stdoutCancels, 1);
      expect(process.stderrCancels, 1);
    }
  });

  test('stdout+stderr合计超过诊断限额立即kill并取消两管道', () async {
    final process = _Process();
    final runner = _Runner((_, __) async {
      process.output.add(List<int>.filled(5, 65));
      process.errors.add(List<int>.filled(5, 66));
      return process;
    });
    await expectLater(
        encoder(runner, maxDiagnostic: 9).encode(input), throwsStateError);
    await process.killed.future.timeout(_guard);
    expect(process.stdoutCancels, 1);
    expect(process.stderrCancels, 1);
  });

  test('管道错误终止编码且错误文本不回显', () async {
    final process = _Process();
    final runner = _Runner((_, __) async {
      process.output.addError(StateError('native-pipe-secret'));
      return process;
    });
    await expectLater(
        encoder(runner).encode(input),
        throwsA(isA<StateError>().having((e) => e.toString(), 'safe pipe error',
            isNot(contains('native-pipe-secret')))));
    expect(process.kills, greaterThanOrEqualTo(1));
    expect(process.stdoutCancels, 1);
    expect(process.stderrCancels, 1);
  });

  test('退出后子进程管道永不结束也受同一总期限限制', () async {
    final process = _Process(closeOnKill: false);
    late String tempPath;
    final runner = _Runner((_, arguments) async {
      tempPath = _snapshot(arguments).parent.path;
      await _output(arguments).writeAsBytes(_webp);
      process.exit(0, closePipes: false);
      return process;
    });
    final watch = Stopwatch()..start();
    await expectLater(
            encoder(runner,
                    timeout: const Duration(milliseconds: 200),
                    cleanup: const Duration(milliseconds: 50))
                .encode(input),
            throwsA(isA<TimeoutException>()))
        .timeout(_guard);
    expect(watch.elapsed, lessThan(_guard));
    expect(process.stdoutCancels, 1);
    expect(process.stderrCancels, 1);
    expect(await Directory(tempPath).exists(), isFalse);
  });

  test('kill失败、exitCode与cancel永久挂起不能超时后无界await', () async {
    final process = _UncooperativeProcess();
    final runner = _Runner((_, __) async => process);
    final watch = Stopwatch()..start();
    await expectLater(
            encoder(runner,
                    timeout: const Duration(milliseconds: 200),
                    cleanup: const Duration(milliseconds: 50))
                .encode(input),
            throwsA(isA<TimeoutException>()))
        .timeout(_guard);
    expect(watch.elapsed, lessThan(_guard));
    expect(process.kills, greaterThanOrEqualTo(1));
    expect(process.cancellations, 2);
  });

  test('Process.start晚返回的handle也会kill并取消管道', () async {
    final launched = Completer<EncoderProcessHandle>();
    final entered = Completer<void>();
    final runner = _Runner((_, __) {
      entered.complete();
      return launched.future;
    });
    final operation = encoder(runner,
            timeout: const Duration(milliseconds: 200),
            cleanup: const Duration(milliseconds: 50))
        .encode(input);
    final result = expectLater(operation, throwsA(isA<TimeoutException>()));
    await entered.future.timeout(_guard);
    await result.timeout(_guard);
    final lateProcess = _Process();
    launched.complete(lateProcess);
    await lateProcess.killed.future.timeout(_guard);
    expect(lateProcess.kills, 1);
  });

  test('可信runner启动异常不回显路径或输入', () async {
    final runner = _Runner((_, __) async {
      throw ProcessException('do-not-echo-exe', ['do-not-echo-input']);
    });
    await expectLater(
        encoder(runner).encode(input),
        throwsA(isA<StateError>().having((e) => e.toString(), 'safe error',
            allOf(isNot(contains('do-not-echo')), contains('无法启动')))));
  });
}
