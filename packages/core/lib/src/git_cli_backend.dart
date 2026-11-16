import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'git_backend.dart';
import 'git_https_token.dart';
import 'git_sync.dart' show GitSyncException;

/// Desktop implementation. No inherited Git configuration or shell evaluation.
class GitCliBackend implements GitBackend {
  final String executable;
  GitHttpsToken? _credential;
  GitCliBackend({this.executable = 'git', GitHttpsToken? credential})
      : _credential = credential;
  late String _root;
  late String _remote;
  late Map<String, String> _environment;
  List<String> _helpers = [];
  bool _opened = false;
  bool _closed = false;
  String get _metadata => p.join(_root, '.git', 'zaizuo-sync');

  @override
  Future<void> open(
      {required String worktreePath,
      required String remoteUrl,
      required bool create}) async {
    if (_opened || _closed) throw StateError('Git backend already bound');
    final credential = _credential;
    if (credential != null) {
      String canonical;
      try {
        canonical = GitHttpsToken.canonicalRepoUrl(remoteUrl);
      } on ArgumentError {
        throw const GitSyncException(
            'credential_remote_mismatch', 'HTTPS凭据与远端仓库不匹配');
      }
      if (canonical != credential.repoUrl) {
        throw const GitSyncException(
            'credential_remote_mismatch', 'HTTPS凭据与远端仓库不匹配');
      }
      _remote = canonical;
    } else {
      _remote = remoteUrl;
    }
    _opened = true;
    _root = worktreePath;
    _environment = cleanEnvironment();
    // Explicit credentials never discover or invoke system credential helpers.
    if (credential == null && remoteUrl.startsWith('https://'))
      _helpers = await readCredentialHelpers(executable, _environment);
    if (create)
      await _run([
        'init',
        '--template=',
        '--object-format=sha1',
        '--initial-branch=main',
        _root
      ]);
  }

  Future<ProcessResult> _run(List<String> args,
      {Set<int> allowed = const {0},
      Map<String, String>? environment,
      bool binary = false,
      bool http11 = false}) async {
    if (!_opened || _closed) throw StateError('Git backend is not open');
    final command = <String>[
      '--no-pager',
      '--no-replace-objects',
      // Windows' default MAX_PATH can reject temporary incoming refs only after
      // the first device branch has been published. Enable Git's own long-path
      // support per child process, never global config or OS/registry policy.
      if (Platform.isWindows) ...['-c', 'core.longpaths=true'],
      '-c',
      'core.hooksPath=${p.join(_metadata, 'empty-hooks')}',
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
      // Local HTTP proxies/accelerators can break Git's HTTP/2 upload with a
      // 502 gateway error while still serving reads. Retried once below.
      if (http11) ...['-c', 'http.version=HTTP/1.1'],
      '-c',
      'credential.helper=',
      for (final helper in _helpers) ...['-c', 'credential.helper=$helper'],
      '-C',
      _root,
      ...args,
    ];
    final processEnvironment = <String, String>{
      ..._environment,
      ...?environment,
    };
    final network = const {'fetch', 'push', 'ls-remote'}.contains(args.first);
    final credential = _credential;
    if (network && credential != null) {
      // Only the exact bound HTTPS remote is reachable by these operations.
      // A global per-process header avoids Git URL-path matching discrepancies
      // (notably a repository URL without a trailing slash). Redirects and
      // submodules are disabled; no helper receives this credential.
      // The child environment is visible to sufficiently privileged/same-user
      // processes: this is a same-user trust boundary, not secret isolation.
      // No header enters argv, persistent config, or our error/log surface.
      final config = <String, String>{
        'http.extraHeader':
            'Authorization: Basic ${base64Encode(utf8.encode('${credential.username}:${credential.token}'))}',
        'http.followRedirects': 'false',
        'http.sslVerify': 'true',
        'credential.helper': '',
        'credential.useHttpPath': 'true',
      };
      processEnvironment['GIT_CONFIG_COUNT'] = '${config.length}';
      var index = 0;
      for (final entry in config.entries) {
        processEnvironment['GIT_CONFIG_KEY_$index'] = entry.key;
        processEnvironment['GIT_CONFIG_VALUE_$index'] = entry.value;
        index++;
      }
    }
    ProcessResult result;
    try {
      result = await Process.run(executable, command,
          environment: processEnvironment,
          includeParentEnvironment: false,
          runInShell: false,
          stdoutEncoding: binary ? null : utf8,
          stderrEncoding: utf8);
    } on ProcessException {
      throw const GitSyncException(
          'git_unavailable', '无法启动系统Git；请检查安装与受信任的可执行路径');
    }
    if (!allowed.contains(result.exitCode)) {
      if (network) {
        final failure = _networkFailure(result.stderr as String);
        if (failure.code == 'remote_gateway_failed' && !http11) {
          // One HTTP/1.1 retry for proxies that break HTTP/2 uploads.
          return _run(args,
              allowed: allowed,
              environment: environment,
              binary: binary,
              http11: true);
        }
        throw failure;
      }
      throw GitSyncException(
          'git_failed', 'Git ${args.first}失败（退出码${result.exitCode}）');
    }
    return result;
  }

  @override
  Future<String?> getRef(String ref) async {
    final r =
        await _run(['rev-parse', '--verify', '--quiet', ref], allowed: {0, 1});
    return r.exitCode == 1 ? null : (r.stdout as String).trim();
  }

  @override
  Future<void> updateRef(String ref, String oid, {String? expectedOld}) async {
    await _run(['update-ref', ref, oid, if (expectedOld != null) expectedOld]);
  }

  @override
  Future<void> deleteRef(String ref) async {
    await _run(['update-ref', '-d', ref]);
  }

  @override
  Future<Map<String, String>> listRefs(String prefix) async =>
      _parseRefs((await _run(
              ['for-each-ref', '--format=%(objectname) %(refname)', prefix]))
          .stdout as String);
  Map<String, String> _parseRefs(String text) {
    final result = <String, String>{};
    for (final line in const LineSplitter().convert(text)) {
      if (line.isEmpty) continue;
      final match = RegExp(r'^([a-f0-9]{40})\s+(\S+)$').firstMatch(line);
      if (match == null || result.containsKey(match.group(2)))
        throw const GitSyncException('invalid_ref', 'Git引用格式无效');
      result[match.group(2)!] = match.group(1)!;
    }
    return result;
  }

  @override
  Future<bool> isAncestor(String oldOid, String newOid) async =>
      (await _run(['merge-base', '--is-ancestor', oldOid, newOid],
              allowed: {0, 1}))
          .exitCode ==
      0;
  @override
  Future<GitObjectInfo> objectInfo(String oidOrPath) async => GitObjectInfo(
      (await _run(['cat-file', '-t', oidOrPath])).stdout.toString().trim(),
      int.parse((await _run(['cat-file', '-s', oidOrPath]))
          .stdout
          .toString()
          .trim()));
  @override
  Future<Uint8List> readBlob(String oidOrPath) async => Uint8List.fromList(
      (await _run(['cat-file', 'blob', oidOrPath], binary: true)).stdout
          as List<int>);
  @override
  Future<List<GitTreeEntry>> listTree(String commit,
      {required bool recursive}) async {
    final text = (await _run(
            ['ls-tree', if (recursive) '-r', '-z', '--full-tree', commit]))
        .stdout as String;
    final result = <GitTreeEntry>[];
    for (final entry in text.split('\u0000')) {
      if (entry.isEmpty) continue;
      final match =
          RegExp(r'^([0-9]+) ([a-z]+) ([a-f0-9]{40})\t(.+)$').firstMatch(entry);
      if (match == null)
        throw const GitSyncException('invalid_tree', 'Git树格式无效');
      result.add(GitTreeEntry(
          mode: match.group(1)!,
          type: match.group(2)!,
          oid: match.group(3)!,
          path: match.group(4)!));
    }
    return result;
  }

  @override
  Future<String> createBlob(Uint8List bytes) async {
    final temp = await Directory(_metadata).createTemp('blob-');
    try {
      final file = File(p.join(temp.path, 'blob'));
      await file.writeAsBytes(bytes, flush: true);
      return (await _run(
              ['hash-object', '-w', '--no-filters', '--', file.path]))
          .stdout
          .toString()
          .trim();
    } finally {
      await temp.delete(recursive: true);
    }
  }

  @override
  Future<String> createTree(Map<String, String> blobs) async {
    final temp = await Directory(_metadata).createTemp('tree-');
    final env = {'GIT_INDEX_FILE': p.join(temp.path, 'index')};
    try {
      await _run(['read-tree', '--empty'], environment: env);
      for (final entry in blobs.entries) {
        await _run([
          'update-index',
          '--add',
          '--cacheinfo',
          '100644,${entry.value},${entry.key}'
        ], environment: env);
      }
      return (await _run(['write-tree'], environment: env))
          .stdout
          .toString()
          .trim();
    } finally {
      await temp.delete(recursive: true);
    }
  }

  @override
  Future<String> createCommit(
          {required String tree,
          required List<String> parents,
          required String message,
          required String authorName,
          required String authorEmail,
          required String committerName,
          required String committerEmail,
          String? authorDate,
          String? committerDate}) async =>
      (await _run([
        'commit-tree',
        tree,
        for (final parent in parents) ...['-p', parent],
        '-m',
        message
      ], environment: {
        'GIT_AUTHOR_NAME': authorName,
        'GIT_AUTHOR_EMAIL': authorEmail,
        'GIT_COMMITTER_NAME': committerName,
        'GIT_COMMITTER_EMAIL': committerEmail,
        if (authorDate != null) 'GIT_AUTHOR_DATE': authorDate,
        if (committerDate != null) 'GIT_COMMITTER_DATE': committerDate
      }))
          .stdout
          .toString()
          .trim();
  @override
  Future<Map<String, String>> advertise(String refPattern) async => _parseRefs(
      (await _run(['ls-remote', '--refs', '--', _remote, refPattern])).stdout
          as String);
  @override
  Future<void> fetch(String refspec) async {
    await _run([
      'fetch',
      '--no-tags',
      '--no-recurse-submodules',
      '--no-write-fetch-head',
      '--',
      _remote,
      refspec
    ]);
  }

  @override
  Future<void> push(String refspec) async {
    await _run(['push', '--no-verify', '--', _remote, refspec]);
  }

  @override
  Future<void> close() async {
    _closed = true;
    _credential = null;
  }

  /// Exposed for tests. Returns only fixed codes and never child output.
  static GitSyncException classifyNetworkFailure(String stderr) =>
      _networkFailure(stderr);

  // Inspect a bounded diagnostic solely to select a fixed, non-secret code.
  // Never return stderr, stdout, a URL, or any substring from the child.
  static GitSyncException _networkFailure(String stderr) {
    final text =
        stderr.substring(0, stderr.length.clamp(0, 16384)).toLowerCase();
    if (RegExp(r'filename too long|file name too long|path too long')
        .hasMatch(text)) {
      return const GitSyncException('git_path_too_long', '本机Git路径超过限制');
    }
    if (RegExp(
            r'\b401\b|auth ?failed|authentication ?failed|could not read username|could not read password|terminal prompts disabled')
        .hasMatch(text)) {
      return const GitSyncException('authentication_failed', 'HTTPS认证失败');
    }
    if (RegExp(r'\b403\b|permission denied').hasMatch(text)) {
      return const GitSyncException('permission_denied', '远端拒绝访问');
    }
    if (RegExp(r'\b404\b|repository not found').hasMatch(text)) {
      return const GitSyncException('repository_unavailable', '仓库不可用');
    }
    if (RegExp(
            r'\b(502|503|504)\b|bad gateway|service unavailable|gateway time-?out')
        .hasMatch(text)) {
      return const GitSyncException(
          'remote_gateway_failed', 'Git服务或中间代理返回网关错误');
    }
    if (RegExp(r'certificate|ssl|tls').hasMatch(text)) {
      return const GitSyncException('tls_failed', 'HTTPS证书或TLS验证失败');
    }
    if (RegExp(
            r'could not resolve|couldn.t resolve|failed to connect|could not connect|connection refused|network is unreachable|connection timed out')
        .hasMatch(text)) {
      return const GitSyncException('network_unavailable', '无法连接远端');
    }
    return const GitSyncException('git_failed', 'Git网络操作失败');
  }

  static Map<String, String> cleanEnvironment() {
    final env = <String, String>{};
    for (final entry in Platform.environment.entries) {
      final n = entry.key.toUpperCase();
      if (!n.startsWith('GIT_') && !n.startsWith('GCM_'))
        env[entry.key] = entry.value;
    }
    final nullFile = Platform.isWindows ? 'NUL' : '/dev/null';
    env.addAll({
      'GIT_CONFIG_NOSYSTEM': '1',
      'GIT_CONFIG_GLOBAL': nullFile,
      'GIT_CONFIG_SYSTEM': nullFile,
      'GIT_TERMINAL_PROMPT': '0',
      'GIT_NO_REPLACE_OBJECTS': '1',
      'GIT_OPTIONAL_LOCKS': '0',
      'GIT_ATTR_NOSYSTEM': '1',
      'GIT_SSH_VARIANT': 'ssh',
      'GIT_SSH_COMMAND':
          'ssh -oBatchMode=yes -oPermitLocalCommand=no -oClearAllForwardings=yes'
    });
    return env;
  }

  static Future<List<String>> readCredentialHelpers(
      String executable, Map<String, String> environment) async {
    final result = <String>[];
    for (final scope in ['--system', '--global']) {
      final env = Map<String, String>.from(environment)
        ..remove('GIT_CONFIG_NOSYSTEM')
        ..remove('GIT_CONFIG_GLOBAL')
        ..remove('GIT_CONFIG_SYSTEM');
      ProcessResult query;
      try {
        query = await Process.run(
            executable, ['config', scope, '--get-all', 'credential.helper'],
            environment: env,
            includeParentEnvironment: false,
            runInShell: false);
      } on ProcessException {
        throw const GitSyncException('git_unavailable', '无法读取系统Git凭据助手');
      }
      if (query.exitCode != 0 && query.exitCode != 1)
        throw const GitSyncException(
            'credential_configuration', '无法安全读取系统Git凭据助手');
      for (final helper
          in const LineSplitter().convert(query.stdout as String)) {
        if (helper.isEmpty) {
          result.clear();
          continue;
        }
        if (!RegExp(r'^[A-Za-z0-9_.-]+(?: --?[A-Za-z0-9_.=-]+)*$')
            .hasMatch(helper))
          throw const GitSyncException(
              'credential_configuration', '不支持shell式凭据助手；请使用系统标准helper');
        result.add(helper);
      }
    }
    return result;
  }
}
