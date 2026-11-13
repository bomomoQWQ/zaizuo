import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show RootIsolateToken;

import 'package:git2dart/git2dart.dart' as git;
import 'package:git2dart_binaries/git2dart_binaries.dart' show AndroidSSLHelper;
import 'package:path/path.dart' as p;
import 'package:zaizuo_core/zaizuo_core.dart';

import 'native_objects.dart';

/// A username and PAT bound to exactly one canonical HTTPS repository URL.
final class GitHttpsCredential {
  final String repositoryUrl;
  final String username;
  final String personalAccessToken;
  GitHttpsCredential({
    required this.repositoryUrl,
    required this.username,
    required this.personalAccessToken,
  }) {
    _https(repositoryUrl);
    if (username.isEmpty ||
        personalAccessToken.isEmpty ||
        username.contains(RegExp(r'[\x00-\x20:]')) ||
        personalAccessToken.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const GitSyncException('invalid_credentials', 'HTTPS凭据格式无效');
    }
  }
  @override
  String toString() => 'GitHttpsCredential(<redacted>)';
}

void _https(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      url.contains(RegExp(r'[\x00-\x20\x7f\\]')) ||
      uri.path.isEmpty ||
      uri.pathSegments.any((s) => s == '.' || s == '..')) {
    throw const GitSyncException('invalid_remote', '只允许无内嵌凭据的HTTPS仓库');
  }
}

/// Embedded libgit2 backend. Construct on the root Flutter isolate, or pass the
/// root's [workerPort] to [EmbeddedGitBackend.connect] in another isolate.
///
/// TLS trusts the supplied bundled PEM, not the operating system trust store.
/// A single root-owned worker serializes native operations for all instances.
/// Fetch pack sizes are not bounded by [maxBlobBytes]; this is a read limit.
final class EmbeddedGitBackend implements GitBackend {
  static Future<SendPort>? _worker;
  GitHttpsCredential? _credential;
  GitHttpsCredential? get credential => _credential;
  final String? bundledCaPath;
  final int maxBlobBytes;
  final bool _local;
  final SendPort? _sharedPort;
  String? _path;
  String? _url;
  bool _closed = false;

  EmbeddedGitBackend({
    required String bundledCaPath,
    GitHttpsCredential? credential,
    this.maxBlobBytes = 64 * 1024 * 1024,
  }) : _credential = credential,
       bundledCaPath = bundledCaPath,
       _local = false,
       _sharedPort = null;

  /// Only for isolated tests using a local absolute bare repository directory.
  EmbeddedGitBackend.testLocalBare({this.maxBlobBytes = 64 * 1024 * 1024})
    : bundledCaPath = null,
      _credential = null,
      _local = true,
      _sharedPort = null;

  EmbeddedGitBackend.connect({
    required SendPort workerPort,
    required String bundledCaPath,
    GitHttpsCredential? credential,
    this.maxBlobBytes = 64 * 1024 * 1024,
  }) : _credential = credential,
       _sharedPort = workerPort,
       bundledCaPath = bundledCaPath,
       _local = false;

  /// Must run on the main Flutter isolate (asset/path-provider access).
  static Future<String> initializeAndroidCertificates() =>
      AndroidSSLHelper.initialize();

  static Future<SendPort> _start() async {
    if (RootIsolateToken.instance == null) {
      throw const GitSyncException('worker_required', '子isolate必须连接主isolate工人');
    }
    final ready = ReceivePort();
    await Isolate.spawn(_serve, ready.sendPort);
    final port = await ready.first as SendPort;
    ready.close();
    return port;
  }

  Future<SendPort> get workerPort =>
      _sharedPort == null ? (_worker ??= _start()) : Future.value(_sharedPort);

  Future<T> _call<T>(String operation, [Object? payload]) async {
    if (_closed || (_path == null && operation != 'open')) {
      throw const GitSyncException('backend_closed', 'Git后端未打开或已经关闭');
    }
    final port = await workerPort;
    final reply = ReceivePort();
    try {
      port.send([
        reply.sendPort,
        operation,
        _path,
        _url,
        _local,
        bundledCaPath,
        credential?.username,
        credential?.personalAccessToken,
        maxBlobBytes,
        payload,
      ]);
      final result = await reply.first as List;
      if (result[0] == false) {
        throw GitSyncException(result[1] as String, result[2] as String);
      }
      return result[1] as T;
    } finally {
      reply.close();
    }
  }

  @override
  Future<void> open({
    required String worktreePath,
    required String remoteUrl,
    required bool create,
  }) async {
    if (_path != null || _closed || maxBlobBytes < 1) {
      throw const GitSyncException('backend_state', 'Git后端只能绑定一次');
    }
    if (!_local) {
      _https(remoteUrl);
      if (bundledCaPath == null ||
          !p.isAbsolute(bundledCaPath!) ||
          (credential != null && credential!.repositoryUrl != remoteUrl)) {
        throw const GitSyncException('invalid_credentials', '凭据或CA未绑定此仓库');
      }
    } else if (!p.isAbsolute(remoteUrl) ||
        FileSystemEntity.typeSync(remoteUrl, followLinks: false) !=
            FileSystemEntityType.directory ||
        !File(p.join(remoteUrl, 'HEAD')).existsSync() ||
        !Directory(p.join(remoteUrl, 'objects')).existsSync()) {
      throw const GitSyncException('unsafe_local_remote', '测试远端必须为本机裸仓库');
    }
    _path = p.absolute(worktreePath);
    _url = remoteUrl;
    try {
      await _call<void>('open', create);
    } catch (_) {
      _closed = true;
      rethrow;
    }
  }

  @override
  Future<String?> getRef(String ref) => _call('getRef', ref);
  @override
  Future<void> updateRef(String ref, String oid, {String? expectedOld}) =>
      _call('updateRef', [ref, oid, expectedOld]);
  @override
  Future<void> deleteRef(String ref) => _call('deleteRef', ref);
  @override
  Future<Map<String, String>> listRefs(String prefix) =>
      _call('listRefs', prefix);
  @override
  Future<bool> isAncestor(String oldOid, String newOid) =>
      _call('isAncestor', [oldOid, newOid]);
  @override
  Future<GitObjectInfo> objectInfo(String oidOrPath) =>
      _call('objectInfo', oidOrPath);
  @override
  Future<Uint8List> readBlob(String oidOrPath) => _call('readBlob', oidOrPath);
  @override
  Future<List<GitTreeEntry>> listTree(
    String commit, {
    required bool recursive,
  }) => _call('listTree', [commit, recursive]);
  @override
  Future<String> createBlob(Uint8List bytes) => _call('createBlob', bytes);
  @override
  Future<String> createTree(Map<String, String> blobs) =>
      _call('createTree', blobs);
  @override
  Future<String> createCommit({
    required String tree,
    required List<String> parents,
    required String message,
    required String authorName,
    required String authorEmail,
    required String committerName,
    required String committerEmail,
    String? authorDate,
    String? committerDate,
  }) => _call('createCommit', [
    tree,
    parents,
    message,
    authorName,
    authorEmail,
    committerName,
    committerEmail,
    authorDate,
    committerDate,
  ]);
  @override
  Future<Map<String, String>> advertise(String refPattern) =>
      _call('advertise', refPattern);
  @override
  Future<void> fetch(String refspec) => _call('fetch', refspec);
  @override
  Future<void> push(String refspec) => _call('push', refspec);
  @override
  Future<void> close() async {
    _closed = true;
    // Dart strings cannot be reliably zeroized. Release our credential reference.
    _credential = null;
  }
}

void _serve(SendPort ready) {
  final requests = ReceivePort();
  ready.send(requests.sendPort);
  // Synchronous dispatch is intentional: native callbacks are shared by upstream.
  requests.listen((dynamic value) {
    final request = value as List;
    final reply = request[0] as SendPort;
    try {
      reply.send([true, _operate(request)]);
    } on GitSyncException catch (error) {
      reply.send([false, error.code, error.message]);
    } catch (_) {
      reply.send([false, 'git_failed', '嵌入式Git操作失败']);
    }
  });
}

void _oid(String value) {
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(value)) {
    throw const GitSyncException('invalid_object', 'Git对象编号无效');
  }
}

void _ref(String value, {bool pattern = false}) {
  final test = pattern ? value.replaceAll('*', 'x') : value;
  if (!test.startsWith('refs/') ||
      test.contains('..') ||
      test.contains('@{') ||
      test.endsWith('/') ||
      test.endsWith('.') ||
      test
          .split('/')
          .any((s) => s.isEmpty || s.startsWith('.') || s.endsWith('.lock')) ||
      test.contains(RegExp(r'[\x00-\x20\x7f~^:?\[\\*]')) ||
      (pattern && '*'.allMatches(value).length > 1)) {
    throw const GitSyncException('invalid_ref', 'Git引用格式无效');
  }
}

void _path(String value) {
  if (value.isEmpty ||
      utf8.encode(value).length > 4096 ||
      value.split('/').length > 64 ||
      value.startsWith('/') ||
      value.contains('\\') ||
      value.contains(RegExp(r'[\x00-\x1f\x7f:]')) ||
      value
          .split('/')
          .any(
            (s) =>
                s.isEmpty || s == '.' || s == '..' || s.toLowerCase() == '.git',
          )) {
    throw const GitSyncException('invalid_tree', 'Git树路径无效');
  }
}

// libgit2/OpenSSL trust state is process-global and adding a CA file can
// accumulate trust. Pin one immutable bundle for this worker's entire lifetime.
Uint8List? _pinnedCaBytes;
File? _pinnedCaSnapshot;
bool _tlsInitializationFailed = false;

bool _sameBytes(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

void _initializeTrust(String path) {
  if (git.Libgit2.featureBackend(git.GitFeature.https) != 'openssl') {
    throw const GitSyncException(
      'unsupported_tls_backend',
      '此libgit2 TLS后端不支持独立捆绑CA；禁止退回系统信任库',
    );
  }
  if (_tlsInitializationFailed) {
    throw const GitSyncException(
      'tls_initialization_failed',
      'CA初始化失败后禁止重试或改信任策略',
    );
  }
  Uint8List bytes;
  try {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('invalid_ca_file');
    }
    final file = File(path);
    if (file.lengthSync() > 4 * 1024 * 1024) throw StateError('ca_limit');
    bytes = file.readAsBytesSync();
    if (bytes.isEmpty || bytes.length > 4 * 1024 * 1024)
      throw StateError('ca_limit');
  } catch (_) {
    throw const GitSyncException('tls_initialization_failed', '无法读取捆绑CA文件');
  }
  final pinned = _pinnedCaBytes;
  if (pinned != null) {
    final equal = _sameBytes(pinned, bytes);
    final snapshot = _pinnedCaSnapshot;
    if (snapshot == null ||
        FileSystemEntity.typeSync(snapshot.path, followLinks: false) !=
            FileSystemEntityType.file ||
        !_sameBytes(snapshot.readAsBytesSync(), pinned)) {
      _tlsInitializationFailed = true;
      throw const GitSyncException(
        'tls_initialization_failed',
        'CA私有快照已变化；禁止继续连接',
      );
    }
    if (!equal) {
      throw const GitSyncException(
        'ca_policy_change_required',
        '进程已绑定其他CA内容；更改信任策略必须重启进程',
      );
    }
    return;
  }
  // Pass a private snapshot to native code, not the caller's mutable pathname.
  // Intentionally retained for the lifetime of the process-global worker:
  // native TLS backends may retain this pathname for later connections.
  final trustDirectory = Directory.systemTemp.createTempSync('zaizuo-trust-');
  final snapshot = File(p.join(trustDirectory.path, 'pinned-ca.pem'));
  snapshot.writeAsBytesSync(bytes, flush: true);
  _pinnedCaSnapshot = snapshot;
  try {
    git.Libgit2.setSSLCertLocations(file: snapshot.path);
    _pinnedCaBytes = Uint8List.fromList(bytes);
  } catch (_) {
    _tlsInitializationFailed = true;
    throw const GitSyncException('tls_initialization_failed', '无法初始化捆绑CA文件');
  }
}

Object? _operate(List r) {
  final op = r[1] as String;
  final root = r[2] as String;
  final url = r[3] as String;
  final local = r[4] as bool;
  final ca = r[5] as String?;
  final limit = r[8] as int;
  final arg = r[9];
  git.Repository? repo;
  git.Config? config;
  Directory? temporary;
  try {
    temporary = Directory.systemTemp.createTempSync('zaizuo-libgit2-');
    for (final level in [
      git.GitConfigLevel.system,
      git.GitConfigLevel.global,
      git.GitConfigLevel.xdg,
      git.GitConfigLevel.programData,
    ]) {
      git.Libgit2.setConfigSearchPath(level: level, path: temporary.path);
    }
    git.Libgit2.templatePath = temporary.path;
    if (!local) _initializeTrust(ca!);
    if (op == 'open' &&
        arg == true &&
        !Directory(p.join(root, '.git')).existsSync()) {
      repo = git.Repository.init(path: root);
    } else {
      // Refuse includes/extensions before libgit2 can consume local config.
      final gitDirectory = p.join(root, '.git');
      final file = File(p.join(gitDirectory, 'config'));
      if (FileSystemEntity.typeSync(gitDirectory, followLinks: false) !=
              FileSystemEntityType.directory ||
          FileSystemEntity.typeSync(file.path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw const GitSyncException(
          'unsafe_configuration',
          'Git目录和配置必须为普通本机文件',
        );
      }
      if (file.existsSync()) {
        final text = file.readAsStringSync();
        if (RegExp(
          r'^\s*\[\s*(include|includeIf|extensions)\b',
          multiLine: true,
          caseSensitive: false,
        ).hasMatch(text)) {
          throw const GitSyncException(
            'unsafe_configuration',
            '不允许Git配置include或扩展',
          );
        }
      }
      repo = git.Repository.open(root);
    }
    final configPath = p.join(temporary.path, 'safe.config');
    File(configPath).writeAsStringSync(
      '[core]\n bare = false\n logAllRefUpdates = false\n[http]\n sslVerify = true\n followRedirects = false\n[fetch]\n recurseSubmodules = false\n[remote "zaizuo"]\n tagOpt = --no-tags\n',
    );
    config = git.Config.open(configPath);
    repo.setConfig(config);
    if (op == 'open') return null;
    final odb = repo.odb;
    try {
      return _dispatch(
        repo,
        odb,
        op,
        arg,
        url,
        local,
        r[6] as String?,
        r[7] as String?,
        limit,
      );
    } finally {
      odb.free();
    }
  } finally {
    repo?.free();
    config?.free();
    temporary?.deleteSync(recursive: true);
  }
}

String? _getRef(git.Repository repo, String ref) {
  _ref(ref);
  if (!git.Reference.list(repo).contains(ref)) return null;
  final oid = git.Reference.nameToId(repo: repo, refName: ref);
  try {
    return oid.sha;
  } finally {
    oid.free();
  }
}

git.Oid _resolve(git.Repository repo, git.Odb odb, String spec) {
  final colon = spec.indexOf(':');
  if (colon < 0) {
    _oid(spec);
    return git.Oid.fromSHA(repo, spec);
  }
  final commit = spec.substring(0, colon);
  final path = spec.substring(colon + 1);
  _oid(commit);
  _path(path);
  final oid = git.Oid.fromSHA(repo, commit);
  try {
    final (size, type) = objectHeader(odb, oid);
    if (type != 'commit' || size > 1024 * 1024) {
      throw const GitSyncException('invalid_object', '无效的commit对象');
    }
    final object = odb.read(oid);
    String tree;
    try {
      tree = utf8.decode(object.dataBytes).split('\n').first.substring(5);
    } finally {
      object.free();
    }
    var current = tree;
    final parts = path.split('/');
    for (var i = 0; i < parts.length; i++) {
      final treeId = git.Oid.fromSHA(repo, current);
      git.Tree? t;
      try {
        final (treeSize, treeType) = objectHeader(odb, treeId);
        if (treeType != 'tree' || treeSize > 16 * 1024 * 1024) {
          throw const GitSyncException('object_limit', 'tree对象超过读取上限');
        }
        t = git.Tree.lookup(repo: repo, oid: treeId);
        final entry = t[parts[i]];
        final id = entry.oid;
        try {
          current = id.sha;
        } finally {
          id.free();
        }
      } finally {
        t?.free();
        treeId.free();
      }
    }
    return git.Oid.fromSHA(repo, current);
  } finally {
    oid.free();
  }
}

Object? _dispatch(
  git.Repository repo,
  git.Odb odb,
  String op,
  dynamic arg,
  String url,
  bool local,
  String? username,
  String? token,
  int limit,
) {
  switch (op) {
    case 'getRef':
      return _getRef(repo, arg as String);
    case 'listRefs':
      final prefix = arg as String;
      _ref('${prefix}x');
      return <String, String>{
        for (final ref in git.Reference.list(repo))
          if (ref.startsWith(prefix)) ref: _getRef(repo, ref)!,
      };
    case 'deleteRef':
      _ref(arg as String);
      if (_getRef(repo, arg) != null)
        git.Reference.remove(repo: repo, name: arg);
      return null;
    case 'updateRef':
      final a = arg as List;
      _ref(a[0] as String);
      _oid(a[1] as String);
      final oid = git.Oid.fromSHA(repo, a[1] as String);
      git.Oid? old;
      try {
        git.Reference ref;
        if (a[2] == null) {
          ref = git.Reference.create(
            repo: repo,
            name: a[0] as String,
            target: oid,
            force: true,
          );
        } else if (a[2] == '0000000000000000000000000000000000000000') {
          ref = git.Reference.create(
            repo: repo,
            name: a[0] as String,
            target: oid,
          );
        } else {
          _oid(a[2] as String);
          old = git.Oid.fromSHA(repo, a[2] as String);
          ref = git.Reference.createMatching(
            repo: repo,
            name: a[0] as String,
            target: oid,
            currentTarget: old,
            force: true,
          );
        }
        ref.free();
      } finally {
        old?.free();
        oid.free();
      }
      return null;
    case 'isAncestor':
      final a = arg as List;
      _oid(a[0] as String);
      _oid(a[1] as String);
      final old = git.Oid.fromSHA(repo, a[0] as String);
      final next = git.Oid.fromSHA(repo, a[1] as String);
      try {
        return a[0] == a[1] || descendant(repo, old, next);
      } finally {
        old.free();
        next.free();
      }
    case 'objectInfo':
    case 'readBlob':
      final oid = _resolve(repo, odb, arg as String);
      try {
        final (size, type) = objectHeader(odb, oid);
        if (op == 'objectInfo') return GitObjectInfo(type, size);
        if (type != 'blob' || size > limit) {
          throw const GitSyncException('object_limit', '对象类型错误或超过读取上限');
        }
        final object = odb.read(oid);
        try {
          return object.dataBytes;
        } finally {
          object.free();
        }
      } finally {
        oid.free();
      }
    case 'createBlob':
      final bytes = arg as Uint8List;
      if (bytes.length > limit)
        throw const GitSyncException('object_limit', '对象超过写入上限');
      return writeObject(odb, bytes, 3);
    case 'createTree':
      return _createTree(repo, (arg as Map).cast<String, String>());
    case 'createCommit':
      return _createCommit(repo, odb, arg as List);
    case 'listTree':
      return _listTree(repo, odb, arg as List);
    case 'advertise':
    case 'fetch':
    case 'push':
      if (!local) _https(url);
      final rejected = <String>[];
      final callbacks = git.Callbacks(
        credentials: username == null
            ? null
            : git.UserPass(username: username, password: token!),
        certificateCheck: (certificate, host, {required valid}) =>
            valid && host.toLowerCase() == Uri.parse(url).host.toLowerCase(),
        pushUpdateReference: (ref, message) {
          if (message.isNotEmpty) rejected.add(ref);
        },
      );
      final remote = git.Remote.create(repo: repo, name: 'zaizuo', url: url);
      try {
        git.Remote.setAutotag(
          repo: repo,
          remote: 'zaizuo',
          value: git.GitRemoteAutotag.none,
        );
        if (op == 'advertise') {
          final pattern = arg as String;
          _ref(pattern, pattern: true);
          final regex = RegExp(
            '^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$',
          );
          final refs = remote.ls(callbacks: callbacks);
          try {
            return <String, String>{
              for (final ref in refs)
                if (regex.hasMatch(ref.name)) ref.name: ref.oid.sha,
            };
          } finally {
            for (final ref in refs) {
              ref.oid.free();
              ref.localId?.free();
            }
          }
        }
        final spec = arg as String;
        final clean = op == 'fetch' && spec.startsWith('+')
            ? spec.substring(1)
            : spec;
        final pair = clean.split(':');
        if (pair.length != 2 || (op == 'push' && spec.startsWith('+'))) {
          throw const GitSyncException('invalid_refspec', '禁止强制推送或非精确refspec');
        }
        _ref(pair[0], pattern: op == 'fetch');
        _ref(pair[1], pattern: op == 'fetch');
        if (pair[0].contains('*') != pair[1].contains('*') ||
            (pair[0].contains('*') && pair[0] != 'refs/heads/dev/*') ||
            !(pair[0] == 'refs/heads/main' ||
                pair[0].startsWith('refs/heads/dev/') ||
                pair[0].startsWith('refs/heads/attachment/')) ||
            (op == 'push' && pair[0] != pair[1])) {
          throw const GitSyncException('invalid_refspec', '只允许受控分支及设备分支通配符');
        }
        if (op == 'fetch') {
          try {
            remote.fetch(refspecs: [spec], callbacks: callbacks);
          } catch (_) {
            throw const GitSyncException('native_fetch_failed', '嵌入式Git获取失败');
          }
        } else {
          try {
            remote.push(refspecs: [spec], callbacks: callbacks);
          } catch (_) {
            // Never surface native messages: they may contain URLs, tokens or
            // untrusted server text. Report the fixed operation stage only.
            throw const GitSyncException('native_push_failed', '嵌入式Git推送失败');
          }
          if (rejected.isNotEmpty)
            throw const GitSyncException('push_rejected', '服务器拒绝Git推送');
        }
        return null;
      } finally {
        remote.free();
      }
    default:
      throw StateError('unknown_operation');
  }
}

String _createTree(git.Repository repo, Map<String, String> blobs) {
  if (blobs.length > 100000) {
    throw const GitSyncException('object_limit', '树输入条目超过上限');
  }
  final root = <String, Object>{};
  for (final entry in blobs.entries) {
    _path(entry.key);
    _oid(entry.value);
    var node = root;
    final parts = entry.key.split('/');
    for (final part in parts.take(parts.length - 1)) {
      final existing = node.putIfAbsent(part, () => <String, Object>{});
      if (existing is! Map<String, Object>)
        throw const GitSyncException('invalid_tree', '树路径冲突');
      node = existing;
    }
    if (node.containsKey(parts.last))
      throw const GitSyncException('invalid_tree', '树路径冲突');
    node[parts.last] = entry.value;
  }
  String build(Map<String, Object> node) {
    final builder = git.TreeBuilder(repo: repo);
    try {
      for (final entry in node.entries) {
        final isTree = entry.value is Map<String, Object>;
        final sha = isTree
            ? build(entry.value as Map<String, Object>)
            : entry.value as String;
        final oid = git.Oid.fromSHA(repo, sha);
        try {
          builder.add(
            filename: entry.key,
            oid: oid,
            filemode: isTree ? git.GitFilemode.tree : git.GitFilemode.blob,
          );
        } finally {
          oid.free();
        }
      }
      final oid = builder.write();
      try {
        return oid.sha;
      } finally {
        oid.free();
      }
    } finally {
      builder.free();
    }
  }

  return build(root);
}

String _createCommit(git.Repository repo, git.Odb odb, List a) {
  _oid(a[0] as String);
  final parents = a[1] as List;
  if (parents.length > 64 || utf8.encode(a[2] as String).length > 1024 * 1024) {
    throw const GitSyncException('object_limit', 'commit输入超过上限');
  }
  void requireType(String id, String expected) {
    _oid(id);
    final oid = git.Oid.fromSHA(repo, id);
    try {
      if (objectHeader(odb, oid).$2 != expected) {
        throw const GitSyncException('invalid_commit', 'commit引用对象类型不符');
      }
    } finally {
      oid.free();
    }
  }

  requireType(a[0] as String, 'tree');
  for (final parent in parents) {
    requireType(parent as String, 'commit');
  }
  for (final i in [3, 4, 5, 6]) {
    if ((a[i] as String).contains(RegExp(r'[\x00-\x1f\x7f<>]'))) {
      throw const GitSyncException('invalid_commit', '提交身份格式无效');
    }
  }
  final now = '${DateTime.now().millisecondsSinceEpoch ~/ 1000} +0000';
  String date(dynamic value) {
    final text = value as String? ?? now;
    if (!RegExp(r'^[0-9]+ [+-][0-9]{4}$').hasMatch(text)) {
      throw const GitSyncException('invalid_commit', '提交时间格式无效');
    }
    return text;
  }

  final message = a[2] as String;
  final raw =
      'tree ${a[0]}\n${(a[1] as List).map((id) => 'parent $id\n').join()}'
      'author ${a[3]} <${a[4]}> ${date(a[7])}\n'
      'committer ${a[5]} <${a[6]}> ${date(a[8])}\n\n'
      '$message${message.endsWith('\n') ? '' : '\n'}';
  return writeObject(odb, Uint8List.fromList(utf8.encode(raw)), 1);
}

List<GitTreeEntry> _listTree(git.Repository repo, git.Odb odb, List a) {
  _oid(a[0] as String);
  final oid = git.Oid.fromSHA(repo, a[0] as String);
  String sha;
  try {
    final (size, type) = objectHeader(odb, oid);
    if (type == 'commit') {
      if (size > 1024 * 1024)
        throw const GitSyncException('object_limit', 'commit超过上限');
      final object = odb.read(oid);
      try {
        sha = utf8.decode(object.dataBytes).split('\n').first.substring(5);
      } finally {
        object.free();
      }
    } else if (type == 'tree') {
      sha = a[0] as String;
    } else {
      throw const GitSyncException('invalid_tree', '对象不是commit或tree');
    }
  } finally {
    oid.free();
  }
  final result = <GitTreeEntry>[];
  void walk(String id, String prefix, int depth) {
    if (depth > 64 || result.length > 100000)
      throw const GitSyncException('object_limit', '树超过遍历上限');
    _oid(id);
    final treeId = git.Oid.fromSHA(repo, id);
    git.Tree? tree;
    try {
      final (treeSize, treeType) = objectHeader(odb, treeId);
      if (treeType != 'tree' || treeSize > 16 * 1024 * 1024) {
        throw const GitSyncException('object_limit', 'tree对象超过读取上限');
      }
      tree = git.Tree.lookup(repo: repo, oid: treeId);
      for (final entry in tree.entries) {
        final child = entry.oid;
        try {
          final path = '$prefix${entry.name}';
          final type = entry.type == git.GitObject.tree
              ? 'tree'
              : entry.type == git.GitObject.commit
              ? 'commit'
              : 'blob';
          if (a[1] == true && type == 'tree') {
            walk(child.sha, '$path/', depth + 1);
          } else {
            result.add(
              GitTreeEntry(
                mode: entry.filemode.value.toRadixString(8).padLeft(6, '0'),
                type: type,
                oid: child.sha,
                path: path,
              ),
            );
          }
        } finally {
          child.free();
        }
      }
    } finally {
      tree?.free();
      treeId.free();
    }
  }

  walk(sha, '', 0);
  return result;
}
