import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'codec.dart';
import 'config.dart';
import 'events.dart';
import 'store.dart';

/// A deliberately small error surface: never include git's stderr or credentials.
class GitSyncException implements Exception {
  final String code;
  final String message;
  const GitSyncException(this.code, this.message);
  @override
  String toString() => 'GitSyncException($code): $message';
}

/// Content-only, per-device Git transport. No remote tree is checked out.
///
/// [worktree] must initially be empty, or a clone created by this adapter. It is
/// NOT a general-purpose adapter for an existing user-owned Git checkout.
class GitSync {
  static final Map<String, Future<void>> _queues = {};
  static final RegExp _device = RegExp(r'^[a-f0-9]{64}$');
  static final RegExp _oid = RegExp(r'^[a-f0-9]{40}$');
  final Directory worktree;
  final String remoteUrl;
  final String deviceId;
  final int segmentSize;
  final int maxEvents;
  final int maxSegmentBytes;
  final int maxDevices;
  final String gitExecutable;
  final List<String> _credentialHelpers;
  final Map<String, String> _environment;
  bool _closed = false;

  GitSync._(
    this.worktree,
    this.remoteUrl,
    this.deviceId,
    this.segmentSize,
    this.maxEvents,
    this.maxSegmentBytes,
    this.maxDevices,
    this.gitExecutable,
    this._credentialHelpers,
    this._environment,
  );

  String get branchRef => 'refs/heads/dev/$deviceId';
  Directory get _metadata =>
      Directory(p.join(worktree.path, '.git', 'zaizuo-sync'));
  File get _pinsFile => File(p.join(_metadata.path, 'pinned_refs.json'));
  Directory get _noHooks => Directory(p.join(_metadata.path, 'empty-hooks'));
  File get _config => File(p.join(worktree.path, '.git', 'config'));
  static const _configText = '[core]\n'
      '\trepositoryformatversion = 0\n'
      '\tbare = false\n'
      '\tfilemode = false\n'
      '\tlogallrefupdates = false\n';

  /// Creates/reopens a dedicated managed local clone without fetching anything.
  ///
  /// Only an absolute local directory, https://, or ssh:// URL is accepted.
  /// Network credentials belong to system Git credential helpers / ssh-agent.
  static Future<GitSync> initialize({
    required Directory worktree,
    required String remoteUrl,
    required String deviceId,
    int segmentSize = 32,
    int maxEvents = 100000,
    int maxSegmentBytes = 64 * 1024 * 1024,
    int maxDevices = 1024,
    String gitExecutable = 'git',
  }) async {
    if (!_device.hasMatch(deviceId)) {
      throw ArgumentError.value(deviceId, 'deviceId', '需要64位小写十六进制设备编号');
    }
    if (segmentSize < 1 ||
        segmentSize > 1000 ||
        maxEvents < 1 ||
        maxSegmentBytes < 1024 ||
        maxDevices < 1) {
      throw ArgumentError('无效归档或资源上限');
    }
    final remote = await _validateRemote(remoteUrl);
    await worktree.create(recursive: true);
    final root = Directory(await worktree.resolveSymbolicLinks());
    final environment = _cleanEnvironment();
    final helpers = remote.startsWith('https://')
        ? await _readCredentialHelpers(gitExecutable, environment)
        : <String>[];
    final sync = GitSync._(root, remote, deviceId, segmentSize, maxEvents,
        maxSegmentBytes, maxDevices, gitExecutable, helpers, environment);
    await sync._exclusive(() async {
      final gitDir = Directory(p.join(root.path, '.git'));
      if (!await gitDir.exists()) {
        if (!await root.list(followLinks: false).isEmpty) {
          throw const GitSyncException(
              'unmanaged_repository', '同步目录必须为空；不接管用户仓库');
        }
        await sync._run([
          'init',
          '--template=',
          '--object-format=sha1',
          '--initial-branch=main',
          root.path,
        ], bootstrap: true);
        await sync._metadata.create(recursive: true);
        await sync._noHooks.create();
        await sync._config.writeAsString(_configText, flush: true);
        await File(p.join(sync._metadata.path, 'identity.json')).writeAsString(
          canonicalJson({
            'version': 1,
            'remote': remote,
            'device': deviceId,
            'segment_size': segmentSize
          }),
          flush: true,
        );
        await sync._writePins(_Pins(null, {}));
      }
      await sync._assertManaged();
      final identity = jsonObject(await File(
        p.join(sync._metadata.path, 'identity.json'),
      ).readAsString());
      if (identity['version'] != 1 ||
          identity['remote'] != remote ||
          identity['device'] != deviceId ||
          identity['segment_size'] != segmentSize) {
        throw const GitSyncException(
            'repository_identity', '同步目录的远端/设备/分段配置不匹配');
      }
      await sync._readPins();
    });
    return sync;
  }

  /// Publishes only this device's original encrypted envelopes. Returns the
  /// number newly added to its branch (zero for an idempotent retry).
  Future<int> push(FileEventStore store) => _exclusive(() async {
        _checkOpen();
        final pins = await _readPins(community: store.trust.communityId);
        final fetched = await _fetch(pins);
        await _checkPinnedContent(pins, fetched, store);
        final remoteHead = fetched[branchRef];
        final localHead = await _localHead(branchRef);
        if (remoteHead != null &&
            localHead != null &&
            !await _ancestor(remoteHead, localHead) &&
            !await _ancestor(localHead, remoteHead)) {
          throw const GitSyncException('local_fork', '同设备本地分支与远端分叉；禁止覆盖');
        }
        final parent = localHead != null &&
                (remoteHead == null || await _ancestor(remoteHead, localHead))
            ? localHead
            : remoteHead;
        final existing = parent == null
            ? <EncryptedEvent>[]
            : await _archive(parent, deviceId, store);
        final own = store.allEnvelopes
            .where((e) => e.origin == deviceId)
            .toList()
          ..sort((a, b) => a.sequence.compareTo(b.sequence));
        await _verifyChain(own, deviceId, store);
        _requirePrefix(existing, own);
        // A remote source is never reconstructed from received events on another
        // device branch: only origin == deviceId gets here.
        final added = own.length - existing.length;
        String? newHead = parent;
        if (added > 0) newHead = await _commit(own, parent);
        if (newHead != null) {
          if (newHead != localHead) {
            await _run([
              'update-ref',
              branchRef,
              newHead,
              localHead ?? '0000000000000000000000000000000000000000'
            ]);
          }
          // No '+', --force or arbitrary destination ref. Local receive-pack
          // does NOT inherit -c core.hooksPath, so inspect the bare side too.
          await _assertLocalRemoteSafe();
          await _run([
            'push',
            '--no-verify',
            '--',
            remoteUrl,
            '$branchRef:$branchRef'
          ]);
          // Verify what the remote advertises after the write. An ambiguous network
          // failure leaves pins unchanged; retry safely reuses the local commit.
          final after = await _fetch(pins);
          if (after[branchRef] == null ||
              !await _ancestor(newHead, after[branchRef]!)) {
            throw const GitSyncException('push_not_observed', '远端未保留刚发布的分支头');
          }
          final published = await _archive(after[branchRef]!, deviceId, store);
          _requirePrefix(own, published);
          final updated = Map<String, String>.from(pins.refs)
            ..[branchRef] = after[branchRef]!;
          await _writePins(_Pins(store.trust.communityId, updated));
        } else if (pins.community == null) {
          await _writePins(_Pins(store.trust.communityId, pins.refs));
        }
        return added;
      });

  /// Validates all advertised device branches before importing any envelope.
  /// Returns the number newly durably imported; retries do not duplicate events.
  Future<int> pull(FileEventStore store) => _exclusive(() async {
        _checkOpen();
        final pins = await _readPins(community: store.trust.communityId);
        final fetched = await _fetch(pins);
        await _checkPinnedContent(pins, fetched, store);
        final candidate = EventIndex();
        for (final event in store.allEnvelopes) {
          await store.trust.verifyEvent(event);
          candidate.acceptVerified(event);
        }
        final events = <EncryptedEvent>[];
        final refs = fetched.keys.toList()..sort();
        for (final ref in refs) {
          final archive = await _archive(
              fetched[ref]!, ref.substring('refs/heads/dev/'.length), store);
          for (final event in archive) {
            candidate.acceptVerified(event);
            events.add(event);
          }
          if (events.length > maxEvents) {
            throw const GitSyncException('archive_limit', '本次同步事件数超过上限');
          }
        }
        var imported = 0;
        for (final event in events) {
          if (await store.import(event)) imported++;
        }
        // Only validated/imported heads are pinned. A failed import never advances
        // pins; events imported before an I/O failure are idempotent on retry.
        await _writePins(_Pins(store.trust.communityId, fetched));
        return imported;
      });

  /// Reads only the signed public main manifest chain. The root fingerprint
  /// must come from outside this repository. A missing first main returns [].
  Future<List<CommunityManifest>> readManifests({
    required String pinnedFingerprint,
  }) =>
      _exclusive(() async {
        _checkOpen();
        final checkpoint = await _readCommunityCheckpoint(pinnedFingerprint);
        final head = await _fetchMain(checkpoint);
        if (head == null) return <CommunityManifest>[];
        final manifests = await _manifestArchive(head, pinnedFingerprint);
        await _verifyCommunityCheckpoint(checkpoint, manifests);
        await _writeCommunityCheckpoint(pinnedFingerprint, head, manifests);
        return List<CommunityManifest>.unmodifiable(manifests);
      });

  /// Publishes a root-signed manifest to main without accepting any private key
  /// or secret credentials. The revision must extend the complete public chain.
  /// Returns 1 for a new revision, 0 for an exact idempotent retry.
  Future<int> publishManifest(
    CommunityManifest manifest, {
    required String pinnedFingerprint,
  }) =>
      _exclusive(() async {
        _checkOpen();
        _validateFingerprint(pinnedFingerprint);
        // Reject wrong roots/signatures before any network credential helper runs.
        await manifest.verify(pinnedFingerprint);
        if (manifest.revision > 10000) {
          throw const GitSyncException('archive_limit', '社区配置版本超过10000上限');
        }
        final checkpoint = await _readCommunityCheckpoint(pinnedFingerprint);
        final remoteHead = await _fetchMain(checkpoint);
        final remote = remoteHead == null
            ? <CommunityManifest>[]
            : await _manifestArchive(remoteHead, pinnedFingerprint);
        await _verifyCommunityCheckpoint(checkpoint, remote);
        final localHead = await _localHead('refs/heads/main');
        if (remoteHead != null &&
            localHead != null &&
            !await _ancestor(remoteHead, localHead) &&
            !await _ancestor(localHead, remoteHead)) {
          throw const GitSyncException('local_fork', '本地主分支与远端分叉；拒绝覆盖');
        }
        final parent = localHead != null &&
                (remoteHead == null || await _ancestor(remoteHead, localHead))
            ? localHead
            : remoteHead;
        final history = parent == null
            ? <CommunityManifest>[]
            : await _manifestArchive(parent, pinnedFingerprint);
        _requireManifestPrefix(remote, history);
        final revision = manifest.revision;
        var added = 0;
        if (revision <= history.length) {
          if (canonicalJson(history[revision - 1].toJson()) !=
                  canonicalJson(manifest.toJson()) ||
              revision != history.length) {
            throw const GitSyncException(
                'manifest_conflict', '不能发布旧版本或替换已发布配置');
          }
        } else {
          if (revision != history.length + 1) {
            throw const GitSyncException('manifest_gap', '主配置版本不连续；禁止跳过中间签名');
          }
          await manifest.verify(pinnedFingerprint,
              previous: history.isEmpty ? null : history.last);
          history.add(manifest);
          added = 1;
        }
        if (history.isEmpty)
          throw const GitSyncException('invalid_manifest', '主配置不能为空');
        final newHead =
            added == 0 ? parent! : await _commitManifests(history, parent);
        if (localHead != newHead) {
          await _run([
            'update-ref',
            'refs/heads/main',
            newHead,
            localHead ?? '0000000000000000000000000000000000000000'
          ]);
        }
        await _assertLocalRemoteSafe();
        await _run([
          'push',
          '--no-verify',
          '--',
          remoteUrl,
          'refs/heads/main:refs/heads/main'
        ]);
        final afterHead = await _fetchMain(checkpoint);
        if (afterHead == null || !await _ancestor(newHead, afterHead)) {
          throw const GitSyncException('push_not_observed', '远端未保留刚发布的主分支');
        }
        final after = await _manifestArchive(afterHead, pinnedFingerprint);
        _requireManifestPrefix(history, after);
        await _writeCommunityCheckpoint(pinnedFingerprint, afterHead, after);
        return added;
      });

  /// Hard per-object ciphertext limit; no plaintext descriptor or key enters Git.
  static const int maxAttachmentBytes = 20 * 1024 * 1024;

  /// Publishes one immutable ciphertext object on its own exact attachment ref.
  /// File paths are trusted local ciphertext paths, never remote message names.
  Future<void> publishAttachment({
    required String objectId,
    required File ciphertext,
  }) =>
      _exclusive(() async {
        _checkOpen();
        _validateAttachmentId(objectId);
        final bytes = await _readAttachmentFile(ciphertext, maxAttachmentBytes);
        if (await sha256Hex(bytes) != objectId) {
          throw const GitSyncException('attachment_hash', '附件密文摘要与对象号不一致');
        }
        final pins = await _readAttachmentPins();
        final known = pins[objectId];
        final remoteHead = await _fetchAttachmentHead(objectId, known);
        if (remoteHead != null) {
          final existing =
              await _attachmentObject(remoteHead, objectId, maxAttachmentBytes);
          if (!equalBytes(existing, bytes)) {
            throw const GitSyncException(
                'attachment_collision', '相同附件对象号对应不同密文');
          }
          pins[objectId] = remoteHead;
          await _writeAttachmentPins(pins);
          return;
        }
        final head = await _commitAttachment(objectId, bytes);
        final ref = 'refs/heads/attachment/$objectId';
        final localHead = await _localHead(ref);
        if (localHead != null && localHead != head) {
          throw const GitSyncException(
              'attachment_collision', '本地附件引用已被其他内容占用');
        }
        await _run([
          'update-ref',
          ref,
          head,
          localHead ?? '0000000000000000000000000000000000000000'
        ]);
        await _assertLocalRemoteSafe();
        // Deterministic root commit makes honest concurrent identical publishers
        // choose the same head. Never force or replace an occupied attachment ref.
        GitSyncException? pushFailure;
        try {
          await _run(['push', '--no-verify', '--', remoteUrl, '$ref:$ref']);
        } on GitSyncException catch (error) {
          if (error.code != 'git_failed') rethrow;
          // Two honest writers can race the bare ref lock even with identical
          // deterministic commits. Only an exact observed final head and blob
          // can turn this ambiguous push failure into successful deduplication.
          pushFailure = error;
        }
        final after = await _fetchAttachmentHead(objectId, known);
        if (after == null && pushFailure != null) throw pushFailure;
        if (after != head) {
          throw const GitSyncException(
              'attachment_collision', '远端未保留发布的不可变附件头');
        }
        await _attachmentObject(after!, objectId, maxAttachmentBytes);
        pins[objectId] = after;
        await _writeAttachmentPins(pins);
      });

  /// Fetches only the requested ref, never all attachment objects. A previously
  /// observed ref being removed/changed fails closed, even for identical bytes.
  Future<Uint8List> fetchAttachment(
    String objectId, {
    int maxBytes = maxAttachmentBytes,
  }) =>
      _exclusive(() async {
        _checkOpen();
        _validateAttachmentId(objectId);
        if (maxBytes < 1 || maxBytes > maxAttachmentBytes) {
          throw ArgumentError('附件接收上限需1字节至20MiB');
        }
        final pins = await _readAttachmentPins();
        final head = await _fetchAttachmentHead(objectId, pins[objectId]);
        if (head == null) {
          throw const GitSyncException('attachment_not_found', '远端尚无此附件对象');
        }
        final bytes = await _attachmentObject(head, objectId, maxBytes);
        pins[objectId] = head;
        await _writeAttachmentPins(pins);
        return bytes;
      });

  /// Waits for already queued work; does not remove clone, pins or lock file.
  Future<void> close() => _exclusive(() async {
        _closed = true;
      });

  void _checkOpen() {
    if (_closed) throw StateError('GitSync已关闭');
  }

  // OS advisory file lock + isolate-local queue. Every instance for this clone
  // shares the queue. Separate clones of the same device are NOT a multi-writer
  // protocol; Git rejects their competing non-fast-forward pushes.
  Future<T> _exclusive<T>(Future<T> Function() action) {
    final key =
        Platform.isWindows ? worktree.path.toLowerCase() : worktree.path;
    final previous = _queues[key] ?? Future<void>.value();
    final done = Completer<T>();
    final next = previous.then((_) async {
      RandomAccessFile? lock;
      try {
        final lockPath = p.join(p.dirname(worktree.path),
            '.${p.basename(worktree.path)}.zaizuo-sync.lock');
        final type = await FileSystemEntity.type(lockPath, followLinks: false);
        if (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.file) {
          throw const GitSyncException('unsafe_lock', '锁文件不能是链接或目录');
        }
        lock = await File(lockPath).open(mode: FileMode.append);
        await lock.lock(FileLock.blockingExclusive);
        final value = await action();
        await lock.unlock();
        await lock.close();
        lock = null;
        done.complete(value);
      } catch (error, stack) {
        done.completeError(error, stack);
      } finally {
        if (lock != null) {
          try {
            await lock.unlock();
          } finally {
            await lock.close();
          }
        }
      }
    });
    // Keep queue errors consumed even when releasing an OS lock fails.
    final settled = next.then<void>((_) {}, onError: (Object _) {});
    _queues[key] = settled;
    unawaited(settled.then((_) {
      if (identical(_queues[key], settled)) _queues.remove(key);
    }));
    return done.future;
  }

  Future<void> _assertManaged() async {
    if (await FileSystemEntity.type(p.join(worktree.path, '.git'),
                followLinks: false) !=
            FileSystemEntityType.directory ||
        await FileSystemEntity.type(_metadata.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await FileSystemEntity.type(_config.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await FileSystemEntity.type(_noHooks.path, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw const GitSyncException('unmanaged_repository', '不是受控同步仓库，或存在不安全链接');
    }
    if (await _config.readAsString() != _configText ||
        !await _noHooks.list(followLinks: false).isEmpty) {
      throw const GitSyncException(
          'unsafe_configuration', '受控Git配置/hooks目录已被修改；拒绝执行');
    }
  }

  Future<ProcessResult> _run(
    List<String> arguments, {
    bool bootstrap = false,
    Set<int> allowed = const {0},
    Map<String, String>? environment,
    bool binaryOutput = false,
  }) async {
    if (!bootstrap) await _assertManaged();
    final command = <String>[
      '--no-pager',
      '--no-replace-objects',
      '-c',
      'core.hooksPath=${_noHooks.path}',
      '-c',
      'protocol.allow=never',
      '-c',
      'protocol.file.allow=always',
      '-c',
      'protocol.https.allow=always',
      '-c',
      'protocol.ssh.allow=always',
      '-c',
      'protocol.ext.allow=never',
      '-c',
      'fetch.recurseSubmodules=false',
      '-c',
      'submodule.recurse=false',
      '-c',
      'gc.auto=0',
      '-c',
      'maintenance.auto=false',
      '-c',
      'commit.gpgSign=false',
      '-c',
      'tag.gpgSign=false',
      '-c',
      'core.fsmonitor=false',
      '-c',
      'core.untrackedCache=false',
      '-c',
      'credential.helper=',
      for (final helper in _credentialHelpers) ...[
        '-c',
        'credential.helper=$helper'
      ],
      '-C',
      worktree.path,
      ...arguments,
    ];
    ProcessResult result;
    try {
      result = await Process.run(
        gitExecutable,
        command,
        environment: {..._environment, ...?environment},
        includeParentEnvironment: false,
        runInShell: false,
        stdoutEncoding: binaryOutput ? null : utf8,
        stderrEncoding: utf8,
      );
    } on ProcessException {
      throw const GitSyncException(
          'git_unavailable', '无法启动系统Git；请检查安装与受信任的可执行路径');
    }
    if (!allowed.contains(result.exitCode)) {
      // Deliberately do not expose stderr, argv or URLs: helper/server errors
      // can contain credentials. Callers receive a stable operation name only.
      throw GitSyncException(
          'git_failed', 'Git ${arguments.first}失败（退出码${result.exitCode}）');
    }
    return result;
  }

  Future<String?> _localHead(String ref) async {
    final result =
        await _run(['rev-parse', '--verify', '--quiet', ref], allowed: {0, 1});
    if (result.exitCode == 1) return null;
    final head = (result.stdout as String).trim();
    if (!_oid.hasMatch(head))
      throw const GitSyncException('invalid_ref', 'Git分支头格式无效');
    return head;
  }

  Future<bool> _ancestor(String oldHead, String newHead) async {
    final result = await _run(['merge-base', '--is-ancestor', oldHead, newHead],
        allowed: {0, 1});
    return result.exitCode == 0;
  }

  Future<Map<String, String>> _fetch(_Pins pins) async {
    final incoming = 'refs/zaizuo-incoming/${randomId(12)}';
    try {
      await _assertLocalRemoteSafe();
      // A fresh namespace is important: a deleted remote branch must not be
      // hidden by a stale remote-tracking ref. Force applies ONLY to this
      // disposable namespace, never to a published device branch.
      await _run([
        'fetch',
        '--no-tags',
        '--no-recurse-submodules',
        '--no-write-fetch-head',
        '--',
        remoteUrl,
        '+refs/heads/dev/*:$incoming/*'
      ]);
      final output = (await _run([
        'for-each-ref',
        '--format=%(refname) %(objectname)',
        '$incoming/'
      ]))
          .stdout as String;
      final fetched = <String, String>{};
      for (final line in const LineSplitter().convert(output)) {
        if (line.isEmpty) continue;
        final fields = line.split(' ');
        if (fields.length != 2 ||
            !fields[0].startsWith('$incoming/') ||
            !_device.hasMatch(fields[0].substring(incoming.length + 1)) ||
            !_oid.hasMatch(fields[1])) {
          throw const GitSyncException('invalid_ref', '远端设备分支名或对象编号无效');
        }
        final ref =
            'refs/heads/dev/${fields[0].substring(incoming.length + 1)}';
        fetched[ref] = fields[1];
        if (fetched.length > maxDevices) {
          throw const GitSyncException('archive_limit', '远端设备分支数超过上限');
        }
        if ((await _run(['cat-file', '-t', fields[1]])).stdout != 'commit\n') {
          throw const GitSyncException('invalid_ref', '设备分支必须指向commit');
        }
      }
      for (final entry in pins.refs.entries) {
        final head = fetched[entry.key];
        if (head == null) {
          throw const GitSyncException('remote_deleted', '已钉住的设备分支被删除；需显式恢复');
        }
        if (!await _ancestor(entry.value, head)) {
          throw const GitSyncException('remote_rewrite', '远端设备分支回退或分叉；拒绝同步');
        }
      }
      return fetched;
    } finally {
      // Retained pins also have private refs, so pruning these temporary refs
      // does not make the old pinned commit eligible for garbage collection.
      final output =
          (await _run(['for-each-ref', '--format=%(refname)', '$incoming/']))
              .stdout as String;
      for (final ref in const LineSplitter().convert(output)) {
        if (ref.startsWith('$incoming/')) await _run(['update-ref', '-d', ref]);
      }
    }
  }

  Future<void> _checkPinnedContent(
      _Pins pins, Map<String, String> fetched, FileEventStore store) async {
    for (final entry in pins.refs.entries) {
      if (entry.value == fetched[entry.key]) continue;
      final origin = entry.key.substring('refs/heads/dev/'.length);
      final before = await _archive(entry.value, origin, store);
      final after = await _archive(fetched[entry.key]!, origin, store);
      _requirePrefix(before, after);
    }
  }

  Future<List<EncryptedEvent>> _archive(
      String head, String origin, FileEventStore store) async {
    final listing = (await _run(['ls-tree', '-r', '-z', '--full-tree', head]))
        .stdout as String;
    final paths = <String>[];
    for (final entry in listing.split('\u0000')) {
      if (entry.isEmpty) continue;
      final match =
          RegExp(r'^100644 blob ([a-f0-9]{40})\t(.+)$').firstMatch(entry);
      final path = match?.group(2);
      if (path == null ||
          !RegExp('^logs/$origin/[0-9]{8}\\.jsonl\$').hasMatch(path)) {
        throw const GitSyncException('invalid_tree', '设备树只允许自身logs中的普通JSONL文件');
      }
      paths.add(path);
      if (paths.length > (maxEvents + segmentSize - 1) ~/ segmentSize) {
        throw const GitSyncException('archive_limit', '归档文件数超过上限');
      }
    }
    paths.sort();
    if (paths.isEmpty)
      throw const GitSyncException('invalid_tree', '设备分支不能没有事件');
    final events = <EncryptedEvent>[];
    for (var i = 0; i < paths.length; i++) {
      final expected = _segmentPath(origin, i);
      if (paths[i] != expected) {
        throw const GitSyncException('invalid_archive', '归档分段编号缺口或名称无效');
      }
      final spec = '$head:${paths[i]}';
      final size = int.tryParse(
          ((await _run(['cat-file', '-s', spec])).stdout as String).trim());
      if (size == null || size < 1 || size > maxSegmentBytes) {
        throw const GitSyncException('archive_limit', '归档分段大小超过上限或为空');
      }
      final text =
          (await _run(['show', '--no-ext-diff', '--no-textconv', spec])).stdout
              as String;
      if (!text.endsWith('\n') || text.contains('\r')) {
        throw const GitSyncException('invalid_archive', 'JSONL必须为完整LF结尾记录');
      }
      final lines = text.substring(0, text.length - 1).split('\n');
      if (lines.isEmpty ||
          lines.length > segmentSize ||
          (i + 1 < paths.length && lines.length != segmentSize)) {
        throw const GitSyncException('invalid_archive', '归档分段记录数无效');
      }
      for (final line in lines) {
        final value = jsonObject(line);
        final event = EncryptedEvent.fromJson(value);
        if (canonicalJson(event.toJson()) != line) {
          throw const GitSyncException('invalid_archive', 'JSONL不是规范化密文信封');
        }
        events.add(event);
        if (events.length > maxEvents) {
          throw const GitSyncException('archive_limit', '归档事件数超过上限');
        }
      }
    }
    await _verifyChain(events, origin, store);
    return events;
  }

  Future<void> _verifyChain(
      List<EncryptedEvent> events, String origin, FileEventStore store) async {
    if (events.length > maxEvents)
      throw const GitSyncException('archive_limit', '归档事件数超过上限');
    EncryptedEvent? previous;
    final ids = <String>{};
    for (final event in events) {
      if (event.origin != origin) {
        throw const GitSyncException('origin_mismatch', '信封来源不匹配设备分支');
      }
      if (event.sequence != (previous?.sequence ?? 0) + 1 ||
          event.previous != previous?.id ||
          (previous != null && event.clock <= previous.clock) ||
          !ids.add(event.id)) {
        throw const GitSyncException('invalid_chain', '设备归档不是连续、单调、无重复的事件链');
      }
      await store.trust.verifyEvent(event);
      previous = event;
    }
  }

  void _requirePrefix(List<EncryptedEvent> before, List<EncryptedEvent> after) {
    if (before.length > after.length) {
      throw const GitSyncException('archive_rewrite', '已知事件被删除；拒绝覆盖归档');
    }
    for (var i = 0; i < before.length; i++) {
      if (canonicalJson(before[i].toJson()) !=
          canonicalJson(after[i].toJson())) {
        throw const GitSyncException('archive_rewrite', '已知事件被改写或分叉');
      }
    }
  }

  String _segmentPath(String origin, int index) =>
      'logs/$origin/${index.toString().padLeft(8, '0')}.jsonl';

  Future<String> _commit(List<EncryptedEvent> own, String? parent) async {
    final temp = await Directory(_metadata.path).createTemp('transaction-');
    final indexEnvironment = {'GIT_INDEX_FILE': p.join(temp.path, 'index')};
    try {
      await _run(['read-tree', '--empty'], environment: indexEnvironment);
      for (var offset = 0; offset < own.length; offset += segmentSize) {
        final end = offset + segmentSize < own.length
            ? offset + segmentSize
            : own.length;
        final contents =
            '${own.sublist(offset, end).map((e) => canonicalJson(e.toJson())).join('\n')}\n';
        if (utf8.encode(contents).length > maxSegmentBytes) {
          throw const GitSyncException('archive_limit', '输出归档分段超过大小上限');
        }
        final file = File(p.join(temp.path, 'blob'));
        await file.writeAsString(contents, flush: true);
        final blob = ((await _run(
                    ['hash-object', '-w', '--no-filters', '--', file.path]))
                .stdout as String)
            .trim();
        if (!_oid.hasMatch(blob))
          throw const GitSyncException('invalid_object', 'Git对象编号无效');
        await _run([
          'update-index',
          '--add',
          '--cacheinfo',
          '100644,$blob,${_segmentPath(deviceId, offset ~/ segmentSize)}'
        ], environment: indexEnvironment);
      }
      final tree = ((await _run(['write-tree'], environment: indexEnvironment))
              .stdout as String)
          .trim();
      if (!_oid.hasMatch(tree))
        throw const GitSyncException('invalid_object', 'Git树编号无效');
      final commit = ((await _run([
        'commit-tree',
        tree,
        if (parent != null) ...['-p', parent],
        '-m',
        'zaizuo: encrypted device archive (${own.length} events)',
      ], environment: {
        'GIT_AUTHOR_NAME': 'zaizuo',
        'GIT_AUTHOR_EMAIL': 'device@zaizuo.invalid',
        'GIT_COMMITTER_NAME': 'zaizuo',
        'GIT_COMMITTER_EMAIL': 'device@zaizuo.invalid',
      }))
              .stdout as String)
          .trim();
      if (!_oid.hasMatch(commit))
        throw const GitSyncException('invalid_object', 'Git提交编号无效');
      return commit;
    } finally {
      // This path was created by createTemp inside the private metadata folder.
      if (p.dirname(temp.path) == _metadata.path)
        await temp.delete(recursive: true);
    }
  }

  Future<_Pins> _readPins({String? community}) async {
    final file = _pinsFile;
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const GitSyncException('missing_pins', '本地pin丢失；禁止静默重新信任远端');
    }
    final value = jsonObject(await file.readAsString());
    if (value['version'] != 1 ||
        value['pinned_refs'] is! Map<String, dynamic> ||
        (value['community'] != null && value['community'] is! String)) {
      throw const GitSyncException('invalid_pins', '本地pin格式无效');
    }
    final bound = value['community'] as String?;
    if (community != null && bound != null && bound != community) {
      throw const GitSyncException('community_mismatch', '同步目录已绑定另一个社区');
    }
    final refs = <String, String>{};
    for (final entry
        in (value['pinned_refs'] as Map<String, dynamic>).entries) {
      if (!RegExp(r'^refs/heads/dev/[a-f0-9]{64}$').hasMatch(entry.key) ||
          entry.value is! String ||
          !_oid.hasMatch(entry.value as String)) {
        throw const GitSyncException('invalid_pins', '本地pin引用无效');
      }
      refs[entry.key] = entry.value as String;
    }
    return _Pins(bound, refs);
  }

  Future<void> _writePins(_Pins pins) async {
    // Private refs retain pinned objects even if an external git gc is run.
    for (final entry in pins.refs.entries) {
      await _run([
        'update-ref',
        'refs/zaizuo-pins/${entry.key.substring('refs/heads/dev/'.length)}',
        entry.value
      ]);
    }
    final temporary = File(p.join(_metadata.path, 'pins-${randomId(12)}.tmp'));
    await temporary.writeAsString(
        canonicalJson({
          'version': 1,
          'community': pins.community,
          'pinned_refs': pins.refs,
        }),
        flush: true);
    // Same-directory rename replaces the file atomically on supported desktop
    // filesystems. Never delete the old pin file first.
    await temporary.rename(_pinsFile.path);
  }

  static Map<String, String> _cleanEnvironment() {
    final environment = <String, String>{};
    for (final entry in Platform.environment.entries) {
      final name = entry.key.toUpperCase();
      if (!name.startsWith('GIT_') && !name.startsWith('GCM_')) {
        environment[entry.key] = entry.value;
      }
    }
    final nullFile = Platform.isWindows ? 'NUL' : '/dev/null';
    environment.addAll({
      'GIT_CONFIG_NOSYSTEM': '1',
      'GIT_CONFIG_GLOBAL': nullFile,
      'GIT_CONFIG_SYSTEM': nullFile,
      'GIT_TERMINAL_PROMPT': '0',
      'GIT_NO_REPLACE_OBJECTS': '1',
      'GIT_OPTIONAL_LOCKS': '0',
      'GIT_ATTR_NOSYSTEM': '1',
      'GIT_SSH_VARIANT': 'ssh',
      'GIT_SSH_COMMAND':
          'ssh -oBatchMode=yes -oPermitLocalCommand=no -oClearAllForwardings=yes',
    });
    return environment;
  }

  static Future<List<String>> _readCredentialHelpers(
      String executable, Map<String, String> environment) async {
    final result = <String>[];
    for (final scope in ['--system', '--global']) {
      final queryEnvironment = Map<String, String>.from(environment)
        ..remove('GIT_CONFIG_NOSYSTEM')
        ..remove('GIT_CONFIG_GLOBAL')
        ..remove('GIT_CONFIG_SYSTEM');
      ProcessResult query;
      try {
        query = await Process.run(
            executable, ['config', scope, '--get-all', 'credential.helper'],
            environment: queryEnvironment,
            includeParentEnvironment: false,
            runInShell: false);
      } on ProcessException {
        throw const GitSyncException('git_unavailable', '无法读取系统Git凭据助手');
      }
      if (query.exitCode != 0 && query.exitCode != 1) {
        throw const GitSyncException(
            'credential_configuration', '无法安全读取系统Git凭据助手');
      }
      for (final helper
          in const LineSplitter().convert(query.stdout as String)) {
        if (helper.isEmpty) {
          result.clear();
          continue;
        }
        // Do not execute !shell helpers or paths/options containing metacharacters.
        if (!RegExp(r'^[A-Za-z0-9_.-]+(?: --?[A-Za-z0-9_.=-]+)*$')
            .hasMatch(helper)) {
          throw const GitSyncException(
              'credential_configuration', '不支持shell式凭据助手；请使用系统标准helper');
        }
        result.add(helper);
      }
    }
    return result;
  }

  void _validateAttachmentId(String objectId) {
    if (!_device.hasMatch(objectId)) throw const FormatException('无效附件密文对象号');
  }

  Future<Uint8List> _readAttachmentFile(File file, int limit) async {
    var path = p.normalize(p.absolute(file.path));
    while (true) {
      if (await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const GitSyncException(
            'unsafe_attachment_path', '附件密文路径不能包含符号链接');
      }
      final parent = p.dirname(path);
      if (parent == path) break;
      path = parent;
    }
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const GitSyncException('unsafe_attachment_path', '附件密文必须是本机普通文件');
    }
    final handle = await file.open(mode: FileMode.read);
    try {
      final length = await handle.length();
      if (length < 1 || length > limit) {
        throw const GitSyncException('attachment_limit', '附件密文为空或超过本机上限');
      }
      final output = BytesBuilder(copy: false);
      while (output.length <= limit) {
        final chunk =
            await handle.read((limit + 1 - output.length).clamp(1, 64 * 1024));
        if (chunk.isEmpty) break;
        output.add(chunk);
      }
      if (output.length < 1 || output.length > limit) {
        throw const GitSyncException('attachment_limit', '附件密文为空或超过本机上限');
      }
      return output.takeBytes();
    } finally {
      await handle.close();
    }
  }

  File get _attachmentPins =>
      File(p.join(_metadata.path, 'attachment_pins.json'));
  File get _attachmentInitialized =>
      File(p.join(_metadata.path, 'attachment_initialized'));

  Future<Map<String, String>> _readAttachmentPins() async {
    await _assertManaged();
    final kind =
        await FileSystemEntity.type(_attachmentPins.path, followLinks: false);
    if (kind == FileSystemEntityType.notFound) {
      final marker = await FileSystemEntity.type(_attachmentInitialized.path,
          followLinks: false);
      final retained = (await _run([
        'for-each-ref',
        '--format=%(refname)',
        'refs/zaizuo-attachment-pins/'
      ]))
          .stdout as String;
      if (marker != FileSystemEntityType.notFound ||
          retained.trim().isNotEmpty) {
        throw const GitSyncException(
            'missing_attachment_pins', '已见附件pin丢失；禁止静默重新信任');
      }
      await _writeAttachmentPins({});
      await _attachmentInitialized.writeAsString('1\n', flush: true);
      return <String, String>{};
    }
    if (kind != FileSystemEntityType.file ||
        await FileSystemEntity.type(_attachmentInitialized.path,
                followLinks: false) !=
            FileSystemEntityType.file ||
        await _attachmentInitialized.readAsString() != '1\n') {
      throw const GitSyncException('invalid_attachment_pins', '附件pin/初始化标记无效');
    }
    final value = jsonObject(await _attachmentPins.readAsString());
    if (value['version'] != 1 || value['objects'] is! Map<String, dynamic>) {
      throw const GitSyncException('invalid_attachment_pins', '附件pin格式无效');
    }
    final pins = <String, String>{};
    for (final entry in (value['objects'] as Map<String, dynamic>).entries) {
      if (!_device.hasMatch(entry.key) ||
          entry.value is! String ||
          !_oid.hasMatch(entry.value as String)) {
        throw const GitSyncException('invalid_attachment_pins', '附件pin内容无效');
      }
      pins[entry.key] = entry.value as String;
    }
    return pins;
  }

  Future<void> _writeAttachmentPins(Map<String, String> pins) async {
    for (final entry in pins.entries) {
      await _run([
        'update-ref',
        'refs/zaizuo-attachment-pins/${entry.key}',
        entry.value
      ]);
    }
    final temporary =
        File(p.join(_metadata.path, 'attachment-pins-${randomId(12)}.tmp'));
    await temporary.writeAsString(
        canonicalJson({'version': 1, 'objects': pins}),
        flush: true);
    await temporary.rename(_attachmentPins.path);
  }

  Future<String?> _fetchAttachmentHead(
      String objectId, String? pinnedHead) async {
    final ref = 'refs/heads/attachment/$objectId';
    await _assertLocalRemoteSafe();
    final advertised =
        ((await _run(['ls-remote', '--refs', '--', remoteUrl, ref])).stdout
                as String)
            .trim();
    if (advertised.isEmpty) {
      if (pinnedHead != null) {
        throw const GitSyncException('attachment_deleted', '已见附件分支被删除；拒绝重新发布');
      }
      return null;
    }
    final fields = advertised.split(RegExp(r'\s+'));
    if (fields.length != 2 || fields[1] != ref || !_oid.hasMatch(fields[0])) {
      throw const GitSyncException('attachment_collision', '远端附件分支格式无效');
    }
    if (pinnedHead != null && pinnedHead != fields[0]) {
      throw const GitSyncException('attachment_rewrite', '不可变附件分支头已变化');
    }
    final incoming = 'refs/zaizuo-attachment-incoming/${randomId(12)}';
    try {
      await _run([
        'fetch',
        '--no-tags',
        '--no-recurse-submodules',
        '--no-write-fetch-head',
        '--',
        remoteUrl,
        '+$ref:$incoming'
      ]);
      final head = await _localHead(incoming);
      if (head == null || head != fields[0]) {
        throw const GitSyncException('attachment_rewrite', '附件分支在读取时发生变化');
      }
      if ((await _run(['cat-file', '-t', head])).stdout != 'commit\n') {
        throw const GitSyncException('attachment_collision', '附件分支必须指向commit');
      }
      return head;
    } finally {
      await _run(['update-ref', '-d', incoming]);
    }
  }

  Future<Uint8List> _attachmentObject(
      String head, String objectId, int limit) async {
    final listing =
        (await _run(['ls-tree', '-z', '--full-tree', head])).stdout as String;
    final match = RegExp(r'^100644 blob ([a-f0-9]{40})\tobject\.bin\x00$')
        .firstMatch(listing);
    if (match == null) {
      throw const GitSyncException(
          'attachment_collision', '附件树只能包含普通object.bin');
    }
    // No event/descriptor/object name is executed; binary bytes bypass UTF-8.
    final blob = match.group(1)!;
    final size = int.tryParse(
        ((await _run(['cat-file', '-s', blob])).stdout as String).trim());
    if (size == null || size < 1 || size > limit || size > maxAttachmentBytes) {
      throw const GitSyncException('attachment_limit', '附件密文对象超过接收上限或为空');
    }
    final result = await _run(['cat-file', 'blob', blob], binaryOutput: true);
    final bytes = Uint8List.fromList(result.stdout as List<int>);
    if (bytes.length != size ||
        bytes.length > limit ||
        await sha256Hex(bytes) != objectId) {
      throw const GitSyncException('attachment_hash', '远端附件密文摘要不符');
    }
    return bytes;
  }

  Future<String> _commitAttachment(String objectId, Uint8List bytes) async {
    final temp =
        await Directory(_metadata.path).createTemp('attachment-transaction-');
    final indexEnvironment = {'GIT_INDEX_FILE': p.join(temp.path, 'index')};
    try {
      await _run(['read-tree', '--empty'], environment: indexEnvironment);
      final file = File(p.join(temp.path, 'ciphertext.snapshot'));
      await file.writeAsBytes(bytes, flush: true);
      final blob =
          ((await _run(['hash-object', '-w', '--no-filters', '--', file.path]))
                  .stdout as String)
              .trim();
      if (!_oid.hasMatch(blob))
        throw const GitSyncException('invalid_object', '附件blob编号无效');
      await _run(
          ['update-index', '--add', '--cacheinfo', '100644,$blob,object.bin'],
          environment: indexEnvironment);
      final tree = ((await _run(['write-tree'], environment: indexEnvironment))
              .stdout as String)
          .trim();
      if (!_oid.hasMatch(tree))
        throw const GitSyncException('invalid_object', '附件tree编号无效');
      final head = ((await _run([
        'commit-tree',
        tree,
        '-m',
        'zaizuo: ciphertext attachment $objectId'
      ], environment: {
        'GIT_AUTHOR_NAME': 'zaizuo',
        'GIT_AUTHOR_EMAIL': 'attachment@zaizuo.invalid',
        'GIT_COMMITTER_NAME': 'zaizuo',
        'GIT_COMMITTER_EMAIL': 'attachment@zaizuo.invalid',
        'GIT_AUTHOR_DATE': '946684800 +0000',
        'GIT_COMMITTER_DATE': '946684800 +0000',
      }))
              .stdout as String)
          .trim();
      if (!_oid.hasMatch(head))
        throw const GitSyncException('invalid_object', '附件commit编号无效');
      return head;
    } finally {
      if (p.dirname(temp.path) == _metadata.path)
        await temp.delete(recursive: true);
    }
  }

  void _validateFingerprint(String fingerprint) {
    if (!_device.hasMatch(fingerprint)) {
      throw ArgumentError('社区根指纹必须是仓库外核对的64位hex');
    }
  }

  File get _communityCheckpoint =>
      File(p.join(_metadata.path, 'community_checkpoint.json'));
  File get _communityInitialized =>
      File(p.join(_metadata.path, 'community_initialized'));

  Future<_CommunityCheckpoint> _readCommunityCheckpoint(
      String fingerprint) async {
    _validateFingerprint(fingerprint);
    await _assertManaged();
    final kind = await FileSystemEntity.type(_communityCheckpoint.path,
        followLinks: false);
    if (kind == FileSystemEntityType.notFound) {
      final marker = await FileSystemEntity.type(_communityInitialized.path,
          followLinks: false);
      final retained = await _localHead('refs/zaizuo-community-pin');
      if (marker != FileSystemEntityType.notFound || retained != null) {
        throw const GitSyncException(
            'missing_checkpoint', '已初始化的主分支checkpoint丢失；禁止重新信任');
      }
      final empty = _CommunityCheckpoint(fingerprint, null, null, 0, null);
      await _writeCommunityRecord(empty);
      await _communityInitialized.writeAsString('1\n', flush: true);
      return empty;
    }
    if (kind != FileSystemEntityType.file) {
      throw const GitSyncException('invalid_checkpoint', '主分支checkpoint不能是链接');
    }
    final json = jsonObject(await _communityCheckpoint.readAsString());
    if (json['version'] != 1 ||
        json['fingerprint'] != fingerprint ||
        json['revision'] is! int ||
        (json['revision'] as int) < 0 ||
        (json['revision'] as int) > 10000) {
      throw const GitSyncException(
          'invalid_checkpoint', '主分支checkpoint格式或根指纹不匹配');
    }
    final revision = json['revision'] as int;
    final head = json['head'];
    final hash = json['manifest_hash'];
    final community = json['community'];
    if (revision == 0
        ? head != null || hash != null || community != null
        : head is! String ||
            !_oid.hasMatch(head) ||
            hash is! String ||
            !_device.hasMatch(hash) ||
            community is! String ||
            community.isEmpty) {
      throw const GitSyncException('invalid_checkpoint', '主分支checkpoint内容不完整');
    }
    final marker = await FileSystemEntity.type(_communityInitialized.path,
        followLinks: false);
    if (marker != FileSystemEntityType.file ||
        await _communityInitialized.readAsString() != '1\n') {
      throw const GitSyncException(
          'missing_checkpoint', '主分支checkpoint标记丢失或格式无效');
    }
    return _CommunityCheckpoint(fingerprint, head as String?,
        community as String?, revision, hash as String?);
  }

  Future<void> _writeCommunityRecord(_CommunityCheckpoint checkpoint) async {
    final temporary =
        File(p.join(_metadata.path, 'community-${randomId(12)}.tmp'));
    await temporary.writeAsString(
        canonicalJson({
          'version': 1,
          'fingerprint': checkpoint.fingerprint,
          'head': checkpoint.head,
          'community': checkpoint.community,
          'revision': checkpoint.revision,
          'manifest_hash': checkpoint.manifestHash,
        }),
        flush: true);
    await temporary.rename(_communityCheckpoint.path);
  }

  Future<void> _writeCommunityCheckpoint(String fingerprint, String head,
      List<CommunityManifest> manifests) async {
    await _run(['update-ref', 'refs/zaizuo-community-pin', head]);
    await _writeCommunityRecord(_CommunityCheckpoint(
        fingerprint,
        head,
        manifests.last.communityId,
        manifests.last.revision,
        await objectHash(manifests.last.toJson())));
  }

  Future<void> _verifyCommunityCheckpoint(
      _CommunityCheckpoint checkpoint, List<CommunityManifest> history) async {
    if (checkpoint.revision == 0) return;
    if (history.length < checkpoint.revision ||
        history.first.communityId != checkpoint.community ||
        await objectHash(history[checkpoint.revision - 1].toJson()) !=
            checkpoint.manifestHash) {
      throw const GitSyncException('manifest_rewrite', '主配置被回退或已验收版本被修改');
    }
  }

  Future<String?> _fetchMain(_CommunityCheckpoint checkpoint) async {
    await _assertLocalRemoteSafe();
    // ls-remote detects deletion without stale refs; fetch uses one exact
    // non-checkout ref and the observed head is re-checked after transfer.
    final advertised = (await _run(
            ['ls-remote', '--refs', '--', remoteUrl, 'refs/heads/main']))
        .stdout as String;
    if (advertised.trim().isEmpty) {
      if (checkpoint.head != null) {
        throw const GitSyncException('remote_deleted', '已钉住的main分支被删除');
      }
      return null;
    }
    final fields = advertised.trim().split(RegExp(r'\s+'));
    if (fields.length != 2 ||
        !_oid.hasMatch(fields[0]) ||
        fields[1] != 'refs/heads/main') {
      throw const GitSyncException('invalid_ref', '远端main引用格式无效');
    }
    final incoming = 'refs/zaizuo-main-incoming/${randomId(12)}';
    try {
      await _run([
        'fetch',
        '--no-tags',
        '--no-recurse-submodules',
        '--no-write-fetch-head',
        '--',
        remoteUrl,
        '+refs/heads/main:$incoming'
      ]);
      final head = await _localHead(incoming);
      if (head == null ||
          (await _run(['cat-file', '-t', head])).stdout != 'commit\n') {
        throw const GitSyncException('invalid_ref', '远端main必须指向commit');
      }
      if (checkpoint.head != null && !await _ancestor(checkpoint.head!, head)) {
        throw const GitSyncException('remote_rewrite', '远端main回退或分叉；拒绝同步');
      }
      return head;
    } finally {
      await _run(['update-ref', '-d', incoming]);
    }
  }

  Future<List<CommunityManifest>> _manifestArchive(
      String head, String fingerprint) async {
    final listing = (await _run(['ls-tree', '-r', '-z', '--full-tree', head]))
        .stdout as String;
    final revisions = <int, String>{};
    var hasPointer = false;
    for (final entry in listing.split('\u0000')) {
      if (entry.isEmpty) continue;
      final match =
          RegExp(r'^100644 blob ([a-f0-9]{40})\t(.+)$').firstMatch(entry);
      final path = match?.group(2);
      if (path == 'manifest.json') {
        hasPointer = true;
        continue;
      }
      final revision = path == null
          ? null
          : RegExp(r'^manifests/([0-9]{8})\.json$').firstMatch(path);
      final number = revision == null ? 0 : int.parse(revision.group(1)!);
      if (number < 1 || number > 10000 || revisions.containsKey(number)) {
        throw const GitSyncException(
            'invalid_manifest_tree', 'main只允许普通签名manifest及逐版本记录');
      }
      revisions[number] = path!;
    }
    if (!hasPointer || revisions.isEmpty || revisions.length > 10000) {
      throw const GitSyncException(
          'invalid_manifest_tree', 'main缺少manifest指针或历史');
    }
    final history = <CommunityManifest>[];
    for (var revision = 1; revision <= revisions.length; revision++) {
      final path = revisions[revision];
      if (path == null)
        throw const GitSyncException('manifest_gap', 'main缺少中间版本');
      final manifest = await _readManifestBlob(head, path);
      if (manifest.revision != revision) {
        throw const GitSyncException('manifest_gap', '文件名与签名版本不一致');
      }
      await manifest.verify(fingerprint,
          previous: history.isEmpty ? null : history.last);
      history.add(manifest);
    }
    final pointer = await _readManifestBlob(head, 'manifest.json');
    if (canonicalJson(pointer.toJson()) !=
        canonicalJson(history.last.toJson())) {
      throw const GitSyncException(
          'invalid_manifest_tree', '根manifest指针不匹配最新版本');
    }
    return history;
  }

  Future<CommunityManifest> _readManifestBlob(String head, String path) async {
    final spec = '$head:$path';
    final size = int.tryParse(
        ((await _run(['cat-file', '-s', spec])).stdout as String).trim());
    if (size == null || size < 1 || size > 4 * 1024 * 1024) {
      throw const GitSyncException('archive_limit', '社区manifest超过4MiB上限');
    }
    final text = (await _run(['show', '--no-ext-diff', '--no-textconv', spec]))
        .stdout as String;
    if (!text.endsWith('\n'))
      throw const GitSyncException('invalid_manifest', 'manifest必须以LF结尾');
    final json = jsonObject(text.substring(0, text.length - 1));
    final manifest = CommunityManifest.fromJson(json);
    if ('${canonicalJson(manifest.toJson())}\n' != text) {
      throw const GitSyncException('invalid_manifest', 'manifest不是规范化公开文档');
    }
    return manifest;
  }

  void _requireManifestPrefix(
      List<CommunityManifest> before, List<CommunityManifest> after) {
    if (before.length > after.length) {
      throw const GitSyncException('manifest_rewrite', '已见社区修订被删除');
    }
    for (var i = 0; i < before.length; i++) {
      if (canonicalJson(before[i].toJson()) !=
          canonicalJson(after[i].toJson())) {
        throw const GitSyncException('manifest_rewrite', '已见社区修订被修改或分叉');
      }
    }
  }

  Future<String> _commitManifests(
      List<CommunityManifest> history, String? parent) async {
    final temp =
        await Directory(_metadata.path).createTemp('community-transaction-');
    final indexEnvironment = {'GIT_INDEX_FILE': p.join(temp.path, 'index')};
    try {
      await _run(['read-tree', '--empty'], environment: indexEnvironment);
      for (var i = 0; i <= history.length; i++) {
        final manifest = i == history.length ? history.last : history[i];
        final path = i == history.length
            ? 'manifest.json'
            : 'manifests/${manifest.revision.toString().padLeft(8, '0')}.json';
        final contents = '${canonicalJson(manifest.toJson())}\n';
        if (utf8.encode(contents).length > 4 * 1024 * 1024) {
          throw const GitSyncException('archive_limit', '社区manifest超过4MiB上限');
        }
        final file = File(p.join(temp.path, 'blob'));
        await file.writeAsString(contents, flush: true);
        final blob = ((await _run(
                    ['hash-object', '-w', '--no-filters', '--', file.path]))
                .stdout as String)
            .trim();
        if (!_oid.hasMatch(blob))
          throw const GitSyncException('invalid_object', 'Git blob编号无效');
        await _run(
            ['update-index', '--add', '--cacheinfo', '100644,$blob,$path'],
            environment: indexEnvironment);
      }
      final tree = ((await _run(['write-tree'], environment: indexEnvironment))
              .stdout as String)
          .trim();
      if (!_oid.hasMatch(tree))
        throw const GitSyncException('invalid_object', 'Git tree编号无效');
      final commit = ((await _run([
        'commit-tree',
        tree,
        if (parent != null) ...['-p', parent],
        '-m',
        'zaizuo: signed community revision ${history.length}',
      ], environment: {
        'GIT_AUTHOR_NAME': 'zaizuo',
        'GIT_AUTHOR_EMAIL': 'community@zaizuo.invalid',
        'GIT_COMMITTER_NAME': 'zaizuo',
        'GIT_COMMITTER_EMAIL': 'community@zaizuo.invalid',
      }))
              .stdout as String)
          .trim();
      if (!_oid.hasMatch(commit))
        throw const GitSyncException('invalid_object', 'Git commit编号无效');
      return commit;
    } finally {
      if (p.dirname(temp.path) == _metadata.path)
        await temp.delete(recursive: true);
    }
  }

  Future<void> _assertLocalRemoteSafe() async {
    if (!p.isAbsolute(remoteUrl)) return;
    final config = File(p.join(remoteUrl, 'config'));
    if (await FileSystemEntity.type(config.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const GitSyncException('unsafe_local_remote', '本机远端必须是普通裸仓库');
    }
    // Local transport launches receive-pack/upload-pack in another process;
    // command-line -c values do not propagate. Never parse its config via git:
    // include/procReceive/custom hooksPath must be rejected before execution.
    var coreSection = false;
    var bare = false;
    final seen = <String>{};
    for (final raw
        in const LineSplitter().convert(await config.readAsString())) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';'))
        continue;
      if (line == '[core]') {
        coreSection = true;
        continue;
      }
      final match = RegExp(r'^([a-z]+)\s*=\s*([a-z0-9]+)$').firstMatch(line);
      final key = match?.group(1);
      final value = match?.group(2);
      const booleans = {
        'filemode',
        'logallrefupdates',
        'symlinks',
        'ignorecase',
        'precomposeunicode'
      };
      if (!coreSection ||
          key == null ||
          !seen.add(key) ||
          !(key == 'repositoryformatversion' && value == '0' ||
              key == 'bare' && value == 'true' ||
              booleans.contains(key) &&
                  (value == 'true' || value == 'false'))) {
        throw const GitSyncException(
            'unsafe_local_remote', '本机裸仓库配置包含非受控选项；拒绝启动远端Git进程');
      }
      if (key == 'bare') bare = true;
    }
    if (!bare) throw const GitSyncException('unsafe_local_remote', '本机远端不是裸仓库');
    final hooks = Directory(p.join(remoteUrl, 'hooks'));
    final kind = await FileSystemEntity.type(hooks.path, followLinks: false);
    if (kind != FileSystemEntityType.notFound) {
      if (kind != FileSystemEntityType.directory) {
        throw const GitSyncException('unsafe_local_remote', '本机远端hooks目录不能是链接');
      }
      await for (final item in hooks.list(followLinks: false)) {
        if (await FileSystemEntity.type(item.path, followLinks: false) !=
                FileSystemEntityType.file ||
            !p.basename(item.path).endsWith('.sample')) {
          throw const GitSyncException(
              'unsafe_local_remote', '本机远端存在活动hook；拒绝执行');
        }
      }
    }
    for (final relative in [
      'commondir',
      'shallow',
      p.join('objects', 'info', 'alternates'),
      p.join('objects', 'info', 'http-alternates')
    ]) {
      if (await FileSystemEntity.type(p.join(remoteUrl, relative),
              followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const GitSyncException(
            'unsafe_local_remote', '本机远端包含非受控对象/公共目录配置');
      }
    }
  }

  static Future<String> _validateRemote(String remote) async {
    if (remote.isEmpty ||
        remote.trim() != remote ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(remote) ||
        remote.contains('::')) {
      throw const GitSyncException('invalid_remote', '远端地址格式不安全');
    }
    if (p.isAbsolute(remote)) {
      if (remote.startsWith('\\\\') ||
          remote.startsWith('//') ||
          !await Directory(remote).exists()) {
        throw const GitSyncException('invalid_remote', '本地远端必须为存在的本机绝对目录');
      }
      return Directory(remote).resolveSymbolicLinks();
    }
    Uri uri;
    try {
      uri = Uri.parse(remote);
    } on FormatException {
      throw const GitSyncException('invalid_remote', '远端URL无效');
    }
    if (remote.contains(' ') ||
        (uri.scheme != 'https' && uri.scheme != 'ssh') ||
        uri.host.isEmpty ||
        !(RegExp(r'^[A-Za-z0-9][A-Za-z0-9.-]*$').hasMatch(uri.host) ||
            InternetAddress.tryParse(uri.host) != null) ||
        uri.path.isEmpty ||
        uri.path == '/' ||
        uri.hasQuery ||
        uri.hasFragment ||
        remote.contains('\\') ||
        remote.contains('%') ||
        RegExp(r'/\.{1,2}(?:/|$)').hasMatch(remote) ||
        uri.pathSegments.any((s) => s == '..' || s == '.') ||
        (uri.scheme == 'https' && uri.userInfo.isNotEmpty) ||
        (uri.scheme == 'ssh' &&
            uri.userInfo.isNotEmpty &&
            !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(uri.userInfo))) {
      throw const GitSyncException(
          'invalid_remote', '只接受无密码/令牌的https或ssh仓库URL');
    }
    return remote;
  }
}

class _CommunityCheckpoint {
  final String fingerprint;
  final String? head;
  final String? community;
  final int revision;
  final String? manifestHash;
  _CommunityCheckpoint(this.fingerprint, this.head, this.community,
      this.revision, this.manifestHash);
}

class _Pins {
  final String? community;
  final Map<String, String> refs;
  _Pins(this.community, this.refs);
}
