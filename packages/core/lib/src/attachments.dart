import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import 'codec.dart';
import 'crypto.dart';
import 'image_codec.dart';

export 'image_codec.dart';

const _attachmentHardLimit = 20 * 1024 * 1024;
final _attachmentHash = RegExp(r'^[a-f0-9]{64}$');
bool _validAttachmentHash(String value) =>
    value.length == 64 && _attachmentHash.hasMatch(value);

/// 密文对象描述必须置于已签名、加密的会话事件中；本对象本身不是授权证明。
/// 不加入新的scope字段以兼容v1；AES-GCM AAD仍绑定ConversationKey.context，
/// runtime引用必须另带scope/epoch并验证事件权限。name/mime不会用作磁盘路径。
class AttachmentDescriptor {
  final String objectId;
  final String name;
  final String mime;
  final int size;
  final String plainHash;
  final String nonce;
  final String tag;
  AttachmentDescriptor({
    required this.objectId,
    required this.name,
    required this.mime,
    required this.size,
    required this.plainHash,
    required this.nonce,
    required this.tag,
  }) {
    validate();
  }

  void validate() {
    if (!_validAttachmentHash(objectId) ||
        !_validAttachmentHash(plainHash) ||
        size < 1 ||
        size > _attachmentHardLimit) {
      throw const FormatException('无效附件摘要或大小');
    }
    _validateAttachmentMetadata(name, mime);
    _attachmentBase64(nonce, 12);
    _attachmentBase64(tag, 16);
  }

  Map<String, dynamic> toJson() => {
        'object_id': objectId,
        'name': name,
        'mime': mime,
        'size': size,
        'plain_hash': plainHash,
        'nonce': nonce,
        'tag': tag,
      };
  factory AttachmentDescriptor.fromJson(Map<String, dynamic> value) {
    const keys = {
      'object_id',
      'name',
      'mime',
      'size',
      'plain_hash',
      'nonce',
      'tag'
    };
    if (value.length != keys.length || !value.keys.every(keys.contains)) {
      throw const FormatException('附件描述含缺失或未知字段');
    }
    return AttachmentDescriptor(
      objectId: readString(value, 'object_id', max: 64),
      name: readString(value, 'name', max: 256),
      mime: readString(value, 'mime', max: 128),
      size: readInt(value, 'size', min: 1, max: _attachmentHardLimit),
      plainHash: readString(value, 'plain_hash', max: 64),
      nonce: readString(value, 'nonce', max: 16),
      tag: readString(value, 'tag', max: 24),
    );
  }
}

void _validateAttachmentMetadata(String name, String mime) {
  if (name.isEmpty ||
      name.length > 256 ||
      utf8.encode(name).length > 1024 ||
      name != name.trim() ||
      name == '.' ||
      name == '..' ||
      name.contains('/') ||
      name.contains('\\') ||
      name.contains(':') ||
      name.endsWith('.') ||
      name.runes.any((r) =>
          r < 32 || r >= 0x7f && r <= 0x9f || r >= 0xd800 && r <= 0xdfff) ||
      mime.length > 128 ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9!#$&^_.+\-]*/[A-Za-z0-9][A-Za-z0-9!#$&^_.+\-]*$')
          .hasMatch(mime)) {
    throw const FormatException('无效附件名称或MIME类型');
  }
}

List<int> _attachmentBase64(String text, int size) {
  try {
    if (text.length != ((size + 2) ~/ 3) * 4) throw const FormatException();
    final bytes = base64Decode(text);
    if (bytes.length != size || base64Encode(bytes) != text) {
      throw const FormatException();
    }
    return bytes;
  } on FormatException {
    throw const FormatException('无效附件nonce/tag编码');
  }
}

Uint8List _attachmentSnapshot(List<int> bytes, int limit) {
  if (bytes.isEmpty ||
      bytes.length > limit ||
      bytes.length > _attachmentHardLimit) {
    throw ArgumentError('附件为空或超过本机上限');
  }
  if (bytes.any((byte) => byte < 0 || byte > 255)) {
    throw ArgumentError('附件含无效字节');
  }
  return Uint8List.fromList(bytes);
}

final class _AttachmentBudget {
  _AttachmentBudget(this.timeout);
  final Duration timeout;
  final Stopwatch clock = Stopwatch()..start();
  void check() {
    if (clock.elapsed >= timeout) throw TimeoutException('附件操作达到本机期限');
  }

  Future<T> wait<T>(Future<T> operation) {
    final remaining = timeout - clock.elapsed;
    return operation
        .timeout(remaining > Duration.zero ? remaining : Duration.zero);
  }
}

/// 只存随机加密后密文摘要命名的对象，不做明文全局去重。传输API不解密。
/// 原子发布保证正常失败不留下半个.bin对象，不等价于断电后磁盘fsync保证。
/// 拒绝已发现的符号链接；Dart无跨平台原子O_NOFOLLOW，不能防同用户恶意
/// 文件系统替换，root应由宿主控制。超时不取消OS已发出的文件I/O。
class EncryptedAttachments {
  final Directory root;
  final int maxBytes;
  final Duration ioTimeout;
  EncryptedAttachments(
    Directory root, {
    this.maxBytes = 2 * 1024 * 1024,
    this.ioTimeout = const Duration(seconds: 30),
  }) : root = Directory(p.normalize(root.absolute.path)) {
    if (maxBytes < 1 ||
        maxBytes > _attachmentHardLimit ||
        ioTimeout <= Duration.zero) {
      throw ArgumentError('附件上限需1字节～20MiB且期限为正');
    }
  }
  File _file(String id) {
    if (!_validAttachmentHash(id)) throw const FormatException('无效附件对象号');
    return File(p.join(root.path, '$id.bin'));
  }

  AttachmentDescriptor _descriptor(AttachmentDescriptor descriptor) {
    final copy = AttachmentDescriptor.fromJson(descriptor.toJson());
    if (copy.size > maxBytes) throw StateError('附件超过本机加载上限');
    return copy;
  }

  Future<AttachmentDescriptor> put(List<int> compressed, ConversationKey key,
      {required String name, required String mime}) async {
    final snapshot = _attachmentSnapshot(compressed, maxBytes);
    _validateAttachmentMetadata(name, mime);
    final budget = _AttachmentBudget(ioTimeout);
    final box = await budget.wait(AesGcm.with256bits().encrypt(snapshot,
        secretKey: SecretKey(key.bytes),
        aad: utf8.encode('zaizuo.attachment.v1:${key.context}')));
    final id = await budget.wait(sha256Hex(box.cipherText));
    final descriptor = AttachmentDescriptor(
        objectId: id,
        name: name,
        mime: mime,
        size: snapshot.length,
        plainHash: await budget.wait(sha256Hex(snapshot)),
        nonce: base64Encode(box.nonce),
        tag: base64Encode(box.mac.bytes));
    await budget.wait(_publish(descriptor, box.cipherText, budget));
    return descriptor;
  }

  Future<List<int>> get(
      AttachmentDescriptor descriptor, ConversationKey key) async {
    final copy = _descriptor(descriptor);
    final budget = _AttachmentBudget(ioTimeout);
    final bytes = await budget.wait(_readCiphertext(copy, budget));
    final clear = await budget.wait(AesGcm.with256bits().decrypt(
        SecretBox(bytes,
            nonce: _attachmentBase64(copy.nonce, 12),
            mac: Mac(_attachmentBase64(copy.tag, 16))),
        secretKey: SecretKey(key.bytes),
        aad: utf8.encode('zaizuo.attachment.v1:${key.context}')));
    if (clear.length != copy.size ||
        await budget.wait(sha256Hex(clear)) != copy.plainHash) {
      throw StateError('附件原文摘要不匹配');
    }
    return Uint8List.fromList(clear).asUnmodifiableView();
  }

  /// 获取已验证大小和SHA-256的密文对象；不需要密钥，不返回磁盘路径。
  Future<List<int>> exportCiphertext(AttachmentDescriptor descriptor) async {
    final copy = _descriptor(descriptor);
    final budget = _AttachmentBudget(ioTimeout);
    return Uint8List.fromList(await budget.wait(_readCiphertext(copy, budget)))
        .asUnmodifiableView();
  }

  /// 导入接收的密文快照：先大小/SHA-256校验再原子发布，无任何解密。
  /// Hash只证明与descriptor相符，不证明发送者或会话授权；由runtime校验引用。
  Future<void> importCiphertext(
      AttachmentDescriptor descriptor, List<int> bytes) async {
    final copy = _descriptor(descriptor);
    final snapshot = _attachmentSnapshot(bytes, maxBytes);
    if (snapshot.length != copy.size) throw StateError('附件密文大小不匹配');
    final budget = _AttachmentBudget(ioTimeout);
    if (await budget.wait(sha256Hex(snapshot)) != copy.objectId) {
      throw StateError('附件密文摘要不匹配');
    }
    await budget.wait(_publish(copy, snapshot, budget));
  }

  Future<void> _checkRoot(_AttachmentBudget budget,
      {bool create = false}) async {
    await _rejectAttachmentLinks(root.path, budget);
    if (create) await budget.wait(root.create(recursive: true));
    await _rejectAttachmentLinks(root.path, budget);
    if (await budget
            .wait(FileSystemEntity.type(root.path, followLinks: false)) !=
        FileSystemEntityType.directory) throw StateError('附件根目录无效');
  }

  Future<List<int>> _readCiphertext(
      AttachmentDescriptor descriptor, _AttachmentBudget budget) async {
    await _checkRoot(budget);
    final file = _file(descriptor.objectId);
    await _rejectAttachmentLinks(file.path, budget);
    if (await budget
            .wait(FileSystemEntity.type(file.path, followLinks: false)) !=
        FileSystemEntityType.file) throw StateError('附件密文对象不存在或不是普通文件');
    var abandoned = false;
    final opening = file.open(mode: FileMode.read);
    unawaited(opening.then<void>((lateHandle) async {
      if (abandoned) {
        try {
          await lateHandle.close().timeout(ioTimeout);
        } catch (_) {}
      }
    }, onError: (Object _) {}));
    final RandomAccessFile handle;
    try {
      handle = await budget.wait(opening);
    } catch (_) {
      abandoned = true;
      rethrow;
    }
    try {
      if (await budget.wait(handle.length()) != descriptor.size) {
        throw StateError('附件密文大小不匹配');
      }
      final builder = BytesBuilder(copy: false);
      while (builder.length <= descriptor.size) {
        budget.check();
        final chunk = await budget.wait(handle
            .read((descriptor.size + 1 - builder.length).clamp(1, 64 * 1024)));
        if (chunk.isEmpty) break;
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      if (bytes.length != descriptor.size ||
          bytes.length > maxBytes ||
          await budget.wait(sha256Hex(bytes)) != descriptor.objectId) {
        throw StateError('附件密文大小或摘要不匹配');
      }
      return bytes;
    } finally {
      try {
        await budget.wait(handle.close());
      } catch (_) {}
    }
  }

  Future<void> _publish(AttachmentDescriptor descriptor, List<int> bytes,
      _AttachmentBudget budget) async {
    await _checkRoot(budget, create: true);
    final target = _file(descriptor.objectId);
    await _rejectAttachmentLinks(target.path, budget);
    var type = await budget
        .wait(FileSystemEntity.type(target.path, followLinks: false));
    if (type == FileSystemEntityType.file) {
      await _readCiphertext(
          descriptor, budget); // idempotent, never overwrite corruption
      return;
    }
    if (type != FileSystemEntityType.notFound) throw StateError('附件目标不是普通对象');
    Directory? stage;
    try {
      var abandoned = false;
      final creating = root.createTemp('.zaizuo-object-');
      unawaited(creating.then<void>((lateDirectory) async {
        if (abandoned) {
          try {
            await lateDirectory.delete(recursive: true).timeout(ioTimeout);
          } catch (_) {}
        }
      }, onError: (Object _) {}));
      final Directory stagingDirectory;
      try {
        stagingDirectory = await budget.wait(creating);
      } catch (_) {
        abandoned = true;
        rethrow;
      }
      stage = stagingDirectory;
      final file = File(p.join(stagingDirectory.path, 'object.tmp'));
      await budget.wait(file.writeAsBytes(bytes, flush: true));
      budget.check();
      await _checkRoot(budget);
      await _rejectAttachmentLinks(target.path, budget);
      type = await budget
          .wait(FileSystemEntity.type(target.path, followLinks: false));
      if (type == FileSystemEntityType.file) {
        await _readCiphertext(descriptor, budget);
      } else if (type == FileSystemEntityType.notFound) {
        budget.check();
        await budget.wait(file.rename(target.path));
      } else {
        throw StateError('附件目标不是普通对象');
      }
    } finally {
      if (stage != null) {
        try {
          await budget.wait(stage.delete(recursive: true));
        } catch (_) {}
      }
    }
  }
}

Future<void> _rejectAttachmentLinks(
    String original, _AttachmentBudget budget) async {
  var path = p.normalize(p.absolute(original));
  while (true) {
    budget.check();
    if (await budget.wait(FileSystemEntity.type(path, followLinks: false)) ==
        FileSystemEntityType.link) throw StateError('附件路径不接受符号链接');
    final parent = p.dirname(path);
    if (parent == path) break;
    path = parent;
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
/// 支持静态PNG/JPEG/WebP头尺寸与像素数预检（与实际snapshot同字节），
/// 但不验证所有原生bitstream，也没有OS内存/磁盘配额或原生解码沙箱；
/// 不可宣传成安全处理任意不可信图片的隔离器。跨平台优先用PreferredImageEncoder。
class CWebpEncoder {
  final String executable;
  final bool lossless;
  final int quality;
  final int maxInputBytes;
  final int maxOutputBytes;
  final int maxDiagnosticBytes;
  final int maxPixels;
  final int maxDimension;
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
    this.maxPixels = 16 * 1024 * 1024,
    this.maxDimension = 16383,
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
        maxPixels < 1 ||
        maxPixels > 64 * 1024 * 1024 ||
        maxDimension < 1 ||
        maxDimension > 16383 ||
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
      final dimensions = readImageDimensions(bytes,
          maxPixels: maxPixels, maxDimension: maxDimension);
      await deadline.wait(snapshot.writeAsBytes(bytes, flush: true),
          reserve: cleanupTimeout);
      final arguments = <String>[
        '-quiet',
        if (lossless) '-lossless',
        '-exact',
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
      final outputDimensions = readImageDimensions(encoded,
          maxPixels: maxPixels, maxDimension: maxDimension);
      if (outputDimensions.format != 'webp' ||
          outputDimensions.width != dimensions.width ||
          outputDimensions.height != dimensions.height) {
        throw StateError('编码器输出尺寸与输入不一致');
      }
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
