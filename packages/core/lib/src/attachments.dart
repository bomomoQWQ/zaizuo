import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import 'codec.dart';
import 'crypto.dart';

/// 仓库只存密文摘要命名的对象，明文摘要放在加密消息中，不做跨会话可观察去重。
class AttachmentDescriptor {
  final String objectId;
  final String name;
  final String mime;
  final int size;
  final String plainHash;
  final String nonce;
  final String tag;
  AttachmentDescriptor(
      {required this.objectId,
      required this.name,
      required this.mime,
      required this.size,
      required this.plainHash,
      required this.nonce,
      required this.tag});
  Map<String, dynamic> toJson() => {
        'object_id': objectId,
        'name': name,
        'mime': mime,
        'size': size,
        'plain_hash': plainHash,
        'nonce': nonce,
        'tag': tag
      };
  factory AttachmentDescriptor.fromJson(Map<String, dynamic> value) =>
      AttachmentDescriptor(
          objectId: readString(value, 'object_id'),
          name: readString(value, 'name', max: 256),
          mime: readString(value, 'mime', max: 128),
          size: readInt(value, 'size', max: 20 * 1024 * 1024),
          plainHash: readString(value, 'plain_hash'),
          nonce: readString(value, 'nonce'),
          tag: readString(value, 'tag'));
}

class EncryptedAttachments {
  final Directory root;
  final int maxBytes;
  EncryptedAttachments(this.root, {this.maxBytes = 2 * 1024 * 1024}) {
    if (maxBytes < 1 || maxBytes > 20 * 1024 * 1024)
      throw ArgumentError('附件上限需1字节～20MiB');
  }
  File _file(String id) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id))
      throw const FormatException('无效附件对象号');
    return File(p.join(root.path, '$id.bin'));
  }

  Future<AttachmentDescriptor> put(List<int> compressed, ConversationKey key,
      {required String name, required String mime}) async {
    if (compressed.isEmpty || compressed.length > maxBytes)
      throw ArgumentError('附件为空或超过发送上限');
    if (name.isEmpty || name.length > 256 || mime.isEmpty || mime.length > 128)
      throw ArgumentError('无效附件描述');
    final box = await AesGcm.with256bits().encrypt(compressed,
        secretKey: SecretKey(key.bytes),
        aad: utf8.encode('zaizuo.attachment.v1:${key.context}'));
    final id = await sha256Hex(box.cipherText);
    await root.create(recursive: true);
    await _file(id).writeAsBytes(box.cipherText, flush: true);
    return AttachmentDescriptor(
        objectId: id,
        name: name,
        mime: mime,
        size: compressed.length,
        plainHash: await sha256Hex(compressed),
        nonce: base64Encode(box.nonce),
        tag: base64Encode(box.mac.bytes));
  }

  Future<List<int>> get(
      AttachmentDescriptor descriptor, ConversationKey key) async {
    if (descriptor.size > maxBytes) throw StateError('附件超过本机加载上限');
    final file = _file(descriptor.objectId);
    if (await file.length() > maxBytes) throw StateError('密文对象过大');
    final bytes = await file.readAsBytes();
    if (await sha256Hex(bytes) != descriptor.objectId)
      throw StateError('附件密文摘要不匹配');
    final clear = await AesGcm.with256bits().decrypt(
        SecretBox(bytes,
            nonce: base64Decode(descriptor.nonce),
            mac: Mac(base64Decode(descriptor.tag))),
        secretKey: SecretKey(key.bytes),
        aad: utf8.encode('zaizuo.attachment.v1:${key.context}'));
    if (clear.length != descriptor.size ||
        await sha256Hex(clear) != descriptor.plainHash)
      throw StateError('附件原文摘要不匹配');
    return clear;
  }
}

/// 仅允许可信宿主/测试提供的进程替身；不能从仓库、消息或远端配置注入。
/// 生产默认使用 [Process.start]，不执行 shell，也不自动下载编码器。
abstract interface class TrustedEncoderProcessRunner {
  Future<EncoderProcessHandle> start(String executable, List<String> arguments);
}

/// 编码器子进程的最小生命周期接口。注入实现也必须遵守本机信任边界。
abstract interface class EncoderProcessHandle {
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  Future<int> get exitCode;
  bool kill();
}

final class _LocalEncoderProcessRunner implements TrustedEncoderProcessRunner {
  const _LocalEncoderProcessRunner();

  @override
  Future<EncoderProcessHandle> start(
      String executable, List<String> arguments) async {
    final process = await Process.start(executable, arguments,
        runInShell: false, mode: ProcessStartMode.normal);
    // Input is an explicit snapshot path, never stdin. Close the unused parent
    // pipe; observe failures without echoing native diagnostics.
    unawaited(process.stdin.close().then<void>((_) {}, onError: (Object _) {}));
    return _LocalEncoderProcess(process);
  }
}

final class _LocalEncoderProcess implements EncoderProcessHandle {
  _LocalEncoderProcess(this.process);
  final Process process;
  @override
  Stream<List<int>> get stdout => process.stdout;
  @override
  Stream<List<int>> get stderr => process.stderr;
  @override
  Future<int> get exitCode => process.exitCode;
  @override
  bool kill() => process.kill(ProcessSignal.sigkill);
}

final class _EncoderDeadline {
  _EncoderDeadline(this.limit);
  final Duration limit;
  final Stopwatch clock = Stopwatch()..start();

  void ensureTime({Duration reserve = Duration.zero}) {
    if (clock.elapsed + reserve >= limit) {
      throw TimeoutException('WebP编码达到本机总期限');
    }
  }

  Future<T> wait<T>(Future<T> operation, {Duration reserve = Duration.zero}) {
    final remaining = limit - clock.elapsed - reserve;
    return operation
        .timeout(remaining > Duration.zero ? remaining : Duration.zero);
  }
}

/// WebP 编码器适配口。可执行文件只能来自宿主明确选择的可信本机配置，
/// 不从仓库、消息、附件名或远端配置读取；Android 图像栈尚未实现。
///
/// 输入按 [maxInputBytes] 有界复制到本次私有临时目录，cwebp 只读取副本，
/// 不再重新打开原路径。发现路径中的符号链接会拒绝，但纯 Dart 没有跨平台
/// O_NOFOLLOW 原子打开，不能隔离同一用户的恶意路径替换或恶意本机程序。
///
/// [timeout] 是包括输入复制、进程/管道等待、输出读取与有限清理的总预算；
/// 其中 [cleanupTimeout] 预留给 kill/join/cancel/delete，不在超时后无界等待。
/// 文件系统/进程创建/订阅取消的底层 OS 调用不保证可撤销；返回后可能仍有
/// 已发起的 OS 清理工作。不能承诺成功回收不可杀死的系统进程或所有临时文件。
///
/// 字节上限不是像素上限：本实现尚未解析所有图像头来限制解码像素，也没有
/// OS 内存/磁盘配额或原生解码沙箱。恶意压缩图像仍可能让 cwebp 大量分配内存；
/// 不可把此包装器宣传为防解码炸弹或安全处理任意不可信图片的隔离器。
class CWebpEncoder {
  final String executable;
  final bool lossless;
  final int quality;
  final int maxInputBytes;
  final int maxOutputBytes;
  final int maxDiagnosticBytes;
  final Duration timeout;
  final Duration cleanupTimeout;
  final TrustedEncoderProcessRunner _runner;

  CWebpEncoder({
    required this.executable,
    this.lossless = true,
    this.quality = 85,
    this.maxInputBytes = 20 * 1024 * 1024,
    int? maxOutputBytes,
    this.maxDiagnosticBytes = 64 * 1024,
    this.timeout = const Duration(seconds: 30),
    this.cleanupTimeout = const Duration(seconds: 2),
    TrustedEncoderProcessRunner? trustedProcessRunner,
  })  : maxOutputBytes = maxOutputBytes ?? maxInputBytes,
        _runner = trustedProcessRunner ?? const _LocalEncoderProcessRunner() {
    if (!p.isAbsolute(executable) ||
        !File(executable).existsSync() ||
        FileSystemEntity.typeSync(executable, followLinks: false) !=
            FileSystemEntityType.file ||
        quality < 0 ||
        quality > 100) {
      throw ArgumentError('请配置本机可信 cwebp 绝对路径');
    }
    if (maxInputBytes < 1 ||
        maxInputBytes > 20 * 1024 * 1024 ||
        this.maxOutputBytes < 1 ||
        this.maxOutputBytes > 20 * 1024 * 1024 ||
        maxDiagnosticBytes < 1 ||
        maxDiagnosticBytes > 1024 * 1024 ||
        cleanupTimeout <= Duration.zero ||
        timeout <= cleanupTimeout) {
      throw ArgumentError('编码字节上限或总期限配置无效');
    }
  }

  Future<List<int>> encode(File input) async {
    final deadline = _EncoderDeadline(timeout);
    Directory? temporary;
    EncoderProcessHandle? process;
    Future<int>? exited;
    Future<EncoderProcessHandle>? starting;
    final subscriptions = <StreamSubscription<List<int>>>[];
    final pipeFailure = Completer<Never>();
    // Observe this future immediately, including failures occurring during setup.
    unawaited(pipeFailure.future.then<void>((_) {}, onError: (Object _) {}));
    final pipesDone = <Future<void>>[];
    var diagnosticBytes = 0;
    var finished = false;
    var processExited = false;
    try {
      final creating = Directory.systemTemp.createTemp('zaizuo-webp-');
      unawaited(creating.then<void>((directory) async {
        if (finished) {
          try {
            await directory.delete(recursive: true).timeout(cleanupTimeout);
          } catch (_) {}
        }
      }, onError: (Object _) {}));
      final directory = await deadline.wait(creating, reserve: cleanupTimeout);
      temporary = directory;
      final snapshot = File(p.join(directory.path, 'input.snapshot'));
      final output = File(p.join(directory.path, 'compressed.webp'));
      final bytes = await deadline.wait(
          _readBounded(input, maxInputBytes, deadline, cleanupTimeout),
          reserve: cleanupTimeout);
      if (bytes.isEmpty) throw StateError('图片输入为空');
      await deadline.wait(snapshot.writeAsBytes(bytes, flush: true),
          reserve: cleanupTimeout);
      final arguments = <String>[
        '-quiet',
        if (lossless) '-lossless',
        '-q',
        '$quality',
        snapshot.path,
        '-o',
        output.path,
      ];
      starting = _runner.start(executable, List.unmodifiable(arguments));
      unawaited(starting.then<void>((lateProcess) {
        if (finished) _discardLateProcess(lateProcess, cleanupTimeout);
      }, onError: (Object _) {}));
      final running = await deadline.wait(starting, reserve: cleanupTimeout);
      process = running;
      exited = running.exitCode.then((code) {
        processExited = true;
        return code;
      });
      // Observe early exit errors before subscriptions are attached.
      unawaited(exited.then<void>((_) {}, onError: (Object _) {}));
      // Both pipes are drained concurrently. Only byte counts are retained;
      // combined overflow actively terminates the encoder instead of counting
      // unbounded output, and no diagnostics are echoed or returned.
      void observe(Stream<List<int>> stream) {
        final done = Completer<void>();
        pipesDone.add(done.future);
        subscriptions.add(stream.listen((chunk) {
          diagnosticBytes += chunk.length;
          if (diagnosticBytes > maxDiagnosticBytes &&
              !pipeFailure.isCompleted) {
            pipeFailure.completeError(StateError('编码器诊断输出超过上限'));
            if (!processExited) {
              try {
                running.kill();
              } catch (_) {}
            }
          }
        }, onError: (Object _, StackTrace __) {
          if (!pipeFailure.isCompleted) {
            pipeFailure.completeError(StateError('编码器管道读取失败'));
          }
          if (!done.isCompleted) done.complete();
        }, onDone: () {
          if (!done.isCompleted) done.complete();
        }, cancelOnError: true));
      }

      observe(running.stdout);
      observe(running.stderr);
      final code = await deadline.wait(
          Future.any<int>([exited, pipeFailure.future]),
          reserve: cleanupTimeout);
      if (code != 0) throw StateError('WebP编码失败');
      await deadline.wait(
          Future.any<void>([
            Future.wait(pipesDone).then<void>((_) {}),
            pipeFailure.future,
          ]),
          reserve: cleanupTimeout);
      final encoded = await deadline.wait(
          _readBounded(output, maxOutputBytes, deadline, cleanupTimeout),
          reserve: cleanupTimeout);
      // This is only a RIFF envelope/magic sanity check, not full WebP decode,
      // pixel validation, a security audit or evidence of lossless fidelity.
      if (!_webpContainer(encoded)) throw StateError('编码器输出不是WebP封装');
      return encoded;
    } on TimeoutException {
      throw TimeoutException('WebP编码达到本机总期限');
    } on FileSystemException {
      throw StateError('图片文件无法读取或编码输出无效');
    } on ProcessException {
      throw StateError('本机WebP编码器无法启动');
    } finally {
      finished = true;
      if (process != null && !processExited) {
        try {
          process.kill();
        } catch (_) {}
      }
      // Start all independent teardown operations before waiting; no operation
      // can consume an extra full timeout after the shared absolute deadline.
      final cleanups = <Future<void>>[
        for (final subscription in subscriptions)
          _ignoreFailure(subscription.cancel()),
        if (exited != null) _ignoreFailure(exited),
      ];
      if (temporary != null) {
        cleanups.add(_ignoreFailure(temporary.delete(recursive: true)));
      }
      try {
        await deadline.wait(Future.wait(cleanups));
      } catch (_) {}
    }
  }

  static Future<void> _ignoreFailure(Future<dynamic> operation) async {
    try {
      await operation;
    } catch (_) {}
  }

  static void _discardLateProcess(
      EncoderProcessHandle process, Duration cleanupTimeout) {
    try {
      process.kill();
    } catch (_) {}
    // Process.start itself cannot be cancelled. A late handle is still killed
    // and all observed futures get bounded handlers, never unbounded joins.
    for (final stream in [process.stdout, process.stderr]) {
      final subscription = stream.listen((_) {}, onError: (Object _) {});
      unawaited(_ignoreFailure(subscription.cancel())
          .timeout(cleanupTimeout, onTimeout: () {}));
    }
    unawaited(_ignoreFailure(process.exitCode)
        .timeout(cleanupTimeout, onTimeout: () {}));
  }

  static Future<void> _rejectLinks(
      File file, _EncoderDeadline deadline, Duration reserve) async {
    var path = p.normalize(file.absolute.path);
    while (true) {
      deadline.ensureTime(reserve: reserve);
      if (await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw StateError('不接受符号链接图片路径');
      }
      final parent = p.dirname(path);
      if (parent == path) break;
      path = parent;
    }
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('图片必须是本机普通文件');
    }
  }

  static Future<List<int>> _readBounded(
      File file, int limit, _EncoderDeadline deadline, Duration reserve) async {
    await _rejectLinks(file, deadline, reserve);
    deadline.ensureTime(reserve: reserve);
    final handle = await file.open(mode: FileMode.read);
    try {
      if (await handle.length() > limit) throw StateError('图片文件超过字节上限');
      final builder = BytesBuilder(copy: false);
      while (builder.length <= limit) {
        deadline.ensureTime(reserve: reserve);
        final bytes =
            await handle.read((limit + 1 - builder.length).clamp(1, 64 * 1024));
        if (bytes.isEmpty) break;
        builder.add(bytes);
      }
      if (builder.length > limit) throw StateError('图片文件超过字节上限');
      return builder.takeBytes();
    } finally {
      await handle.close();
    }
  }

  static bool _webpContainer(List<int> bytes) {
    if (bytes.length < 12 ||
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) != 'WEBP') {
      return false;
    }
    final size = bytes[4] | bytes[5] << 8 | bytes[6] << 16 | bytes[7] << 24;
    return size + 8 == bytes.length;
  }
}
