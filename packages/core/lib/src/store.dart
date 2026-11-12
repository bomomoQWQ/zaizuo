import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'codec.dart';
import 'crypto.dart';
import 'devices.dart';
import 'events.dart';

class FileEventStore {
  static final Set<String> _openPaths = {};
  final Directory directory;
  final TrustStore trust;
  final String storeId;
  final RandomAccessFile _lock;
  final StreamController<EncryptedEvent> _events = StreamController.broadcast();
  final List<EncryptedEvent> _all;
  EventIndex _index;
  Future<void> _tail = Future.value();
  bool _closed = false;
  bool _closingRequested = false;
  bool _writeFailed = false;
  Future<void>? _closing;
  FileEventStore._(this.directory, this.trust, this.storeId, this._lock,
      this._all, this._index);
  Stream<EncryptedEvent> get events => _events.stream;
  EventIndex get index => _index;
  List<EncryptedEvent> get allEnvelopes => List.unmodifiable(_all);
  File get logFile => File(p.join(directory.path, 'events.jsonl'));

  static Future<FileEventStore> open(
      Directory directory, TrustStore trust) async {
    await directory.create(recursive: true);
    final root = p.normalize(await directory.resolveSymbolicLinks());
    final lockId = Platform.isWindows ? root.toLowerCase() : root;
    if (!_openPaths.add(lockId)) throw StateError('日志已被当前进程打开');
    RandomAccessFile? lock;
    try {
      await directory.create(recursive: true);
      lock =
          await File(p.join(root, 'writer.lock')).open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      final metadata = File(p.join(root, 'store.json'));
      String id;
      if (await metadata.exists()) {
        final data = jsonObject(await metadata.readAsString());
        if (data['community'] != trust.communityId)
          throw StateError('本地日志社区不匹配');
        id = readString(data, 'store_id');
      } else {
        id = randomId();
        await metadata.writeAsString(
            canonicalJson({'store_id': id, 'community': trust.communityId}),
            flush: true);
      }
      final log = File(p.join(root, 'events.jsonl'));
      final all = <EncryptedEvent>[];
      final index = EventIndex();
      if (await log.exists()) {
        final text = await log.readAsString();
        if (text.isNotEmpty && !text.endsWith('\n'))
          throw StateError('发现未完成日志尾部；保留原件，需显式恢复，禁止继续写入');
        for (final line in const LineSplitter().convert(text)) {
          if (line.isEmpty) continue;
          final event = EncryptedEvent.fromJson(jsonObject(line));
          await trust.verifyEvent(event);
          index.acceptVerified(event);
          all.add(event);
        }
      }
      return FileEventStore._(Directory(root), trust, id, lock, all, index);
    } catch (_) {
      if (lock != null) await lock.close();
      _openPaths.remove(lockId);
      rethrow;
    }
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    if (_closingRequested || _closed) {
      return Future<T>.error(StateError('日志已关闭'));
    }
    final done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        if (_closed) throw StateError('日志已关闭');
        if (_writeFailed) throw StateError('日志写入结果不确定；必须关闭并显式检查/恢复');
        done.complete(await action());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<EncryptedEvent> append(
          {required DeviceCredentials device,
          required ConversationKey key,
          required Map<String, dynamic> body,
          String? eventId,
          DateTime? now}) =>
      _serial(() async {
        final certificate = device.certificate;
        if (certificate == null) throw StateError('设备未授权');
        final event = await EncryptedEvent.create(
            communityId: trust.communityId,
            device: device,
            key: key,
            sequence: _index.headSequence(certificate.id) + 1,
            clock: _index.maxClock + 1,
            previous: _index.headId(certificate.id),
            body: body,
            eventId: eventId,
            now: now);
        await _import(event);
        return event;
      });

  Future<bool> import(EncryptedEvent event) => _serial(() => _import(event));
  Future<bool> _import(EncryptedEvent event) async {
    await trust.verifyEvent(event);
    for (final existing in _all) {
      if (existing.id == event.id) {
        if (canonicalJson(existing.toJson()) != canonicalJson(event.toJson()))
          throw StateError('事件编号冲突');
        return false;
      }
    }
    // 原型以重建候选索引实现“验完才落盘、落盘后才确认”，不修改旧索引后回滚。
    final candidate = EventIndex();
    for (final existing in _all) {
      candidate.acceptVerified(existing);
    }
    final accepted = candidate.acceptVerified(event);
    final line = '${canonicalJson(event.toJson())}\n';
    try {
      await logFile.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (_) {
      // A partial append or failed flush may have reached disk. Never append
      // another JSON document after an uncertain tail or acknowledge success.
      _writeFailed = true;
      rethrow;
    }
    _all.add(event);
    _index = candidate;
    for (final added in accepted) {
      _events.add(added);
    }
    return true;
  }

  Future<Map<String, dynamic>> sync({String? cursor, int limit = 100}) =>
      _serial(() async =>
          _index.sync(storeId: storeId, cursor: cursor, limit: limit));
  Future<void> close() {
    _closingRequested = true;
    return _closing ??= _close();
  }

  Future<void> _close() async {
    await _tail;
    _closed = true;
    try {
      await _events.close();
    } finally {
      try {
        await _lock.unlock();
      } finally {
        try {
          await _lock.close();
        } finally {
          _openPaths.remove(Platform.isWindows
              ? directory.path.toLowerCase()
              : directory.path);
        }
      }
    }
  }
}
