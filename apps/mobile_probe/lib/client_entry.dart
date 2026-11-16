import 'dart:io';

// Keep the SDK compatibility export while the test client targets Flutter 3.50.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_git_mobile/git_mobile.dart';
import 'package:zaizuo_runtime/zaizuo_runtime.dart';

import 'client_app.dart';
import 'git_config_store.dart';
import 'git_token_store.dart';
import 'client_controller.dart';
import 'main.dart' show MobileProbe;

String startupFailureCode(Object error) => switch (error) {
  FileSystemException() => 'directory_io_${error.osError?.errorCode ?? 0}',
  MissingPluginException() => 'path_plugin_missing',
  PlatformException() => 'path_platform_failure',
  ArgumentError() => 'path_argument_failure',
  StateError() => 'path_state_failure',
  _ => 'path_initialization_failure',
};

/// Resolves only local application storage; startup never contacts a remote.
class ClientEntry extends StatefulWidget {
  const ClientEntry({super.key, this.dataDirectory});
  final String? dataDirectory;
  @override
  State<ClientEntry> createState() => _ClientEntryState();
}

class _ClientEntryState extends State<ClientEntry> {
  final navigatorKey = GlobalKey<NavigatorState>();
  GitHttpsToken? _sessionCredential;

  Future<GitSync> _gitFactory(
    LocalProfile profile,
    String remote,
    Directory dir,
  ) async {
    final credential = _sessionCredential;
    if (Platform.isAndroid) {
      if (credential == null) {
        final backend = EmbeddedGitBackend(
          bundledCaPath:
              await EmbeddedGitBackend.initializeAndroidCertificates(),
        );
        return GitSync.initializeWithBackend(
          backend: backend,
          worktree: dir,
          remoteUrl: remote,
          deviceId: profile.device.certificate!.id,
        );
      }
      final backend = EmbeddedGitBackend(
        bundledCaPath: await EmbeddedGitBackend.initializeAndroidCertificates(),
        credential: GitHttpsCredential(
          repositoryUrl: remote,
          username: credential.username,
          personalAccessToken: credential.token,
        ),
      );
      return GitSync.initializeWithBackend(
        backend: backend,
        worktree: dir,
        remoteUrl: remote,
        deviceId: profile.device.certificate!.id,
      );
    }
    if (credential != null) {
      return GitSync.initializeWithBackend(
        backend: GitCliBackend(credential: credential),
        worktree: dir,
        remoteUrl: remote,
        deviceId: profile.device.certificate!.id,
      );
    }
    return GitSync.initialize(
      worktree: dir,
      remoteUrl: remote,
      deviceId: profile.device.certificate!.id,
    );
  }

  Future<void> _configureGit(
    ClientController client,
    String remote,
    String username,
    String? token,
    bool remember,
    bool useSaved,
    bool forget,
  ) async {
    // Storage and validation failures must surface as stable Git codes, not the
    // generic operation_failed fallback.
    try {
      await _configureGitInner(
        client,
        remote,
        username,
        token,
        remember,
        useSaved,
        forget,
      );
    } on GitSyncException {
      rethrow;
    } on GitTokenStoreException catch (error) {
      throw GitSyncException(
        error.code == 'credential_unsupported'
            ? 'credential_unsupported'
            : error.code,
        '本机令牌存储不可用',
      );
    } on ArgumentError {
      throw const GitSyncException('invalid_credentials', 'HTTPS地址、用户名或令牌格式无效');
    }
  }

  Future<void> _configureGitInner(
    ClientController client,
    String remote,
    String username,
    String? token,
    bool remember,
    bool useSaved,
    bool forget,
  ) async {
    final store = GitTokenStore(
      Directory(p.join(client.root.path, 'git-credentials')),
    );
    if (forget) {
      await client.disconnectGit();
      if (client.error != null)
        throw const GitSyncException('git_failed', '未能断开当前连接');
      _sessionCredential = null;
      await store.delete(repositoryUrl: remote, username: username);
      await GitConfigStore(client.root).clear();
      return;
    }
    if (remote.trim().isEmpty || username.trim().isEmpty) {
      throw const GitSyncException('invalid_credentials', '缺少仓库地址或用户名');
    }
    String? secret = token;
    if (secret == null && useSaved) {
      secret = await store.read(repositoryUrl: remote, username: username);
      if (secret == null)
        throw const GitSyncException('credentials_required', '此范围无已保存令牌');
    }
    final credential = secret == null
        ? null
        : GitHttpsToken(repoUrl: remote, username: username, token: secret);
    if (credential != null && remember && token != null) {
      await store.save(
        repositoryUrl: remote,
        username: username,
        token: secret!,
      );
    }
    _sessionCredential = credential;
    try {
      await client.configureGit(remote);
    } finally {
      _sessionCredential = null;
    }
    if (client.error == null) {
      // Remember the binding (never the token) so an upgraded client reconnects
      // the same repository without retyping the address.
      await GitConfigStore(client.root).save(
        GitConfig(
          remote: remote,
          username: username,
          remember: remember && credential != null,
        ),
      );
    }
  }

  /// Restores the saved binding after unlock. Only local state is touched:
  /// GitSync.initialize does not fetch, and no network call happens here.
  Future<void> _restoreGit(ClientController client) async {
    final saved = await GitConfigStore(client.root).load();
    if (saved == null || client.isOpen == false) return;
    String? secret;
    if (saved.remember) {
      try {
        secret = await GitTokenStore(
          Directory(p.join(client.root.path, 'git-credentials')),
        ).read(repositoryUrl: saved.remote, username: saved.username);
      } on GitTokenStoreException {
        secret =
            null; // A missing/undecryptable token must not block unlocking.
      }
    }
    _sessionCredential = secret == null
        ? null
        : GitHttpsToken(
            repoUrl: saved.remote,
            username: saved.username,
            token: secret,
          );
    try {
      await client.configureGit(saved.remote);
    } catch (_) {
      // Reported through client.error; the workspace still opens normally.
    } finally {
      _sessionCredential = null;
    }
  }

  late Future<Directory> root = _root();
  String? _selectedDirectory;

  void _retry({bool portable = false}) {
    if (portable) {
      _selectedDirectory = p.join(
        File(Platform.resolvedExecutable).parent.path,
        'zaizuo-data',
      );
    }
    setState(() => root = _root());
  }

  Future<Directory> _root() async {
    String path;
    final explicitDirectory = _selectedDirectory ?? widget.dataDirectory;
    if (explicitDirectory != null) {
      if (!p.isAbsolute(explicitDirectory)) {
        throw StateError('data_directory_must_be_absolute');
      }
      path = explicitDirectory;
    } else if (Platform.isAndroid) {
      final value = await const MethodChannel('zaizuo.mobile_probe/native')
          .invokeMapMethod<String, dynamic>('environment');
      final native = value?['privateRoot'];
      if (native is! String) throw StateError('private_directory_unavailable');
      path = p.join(native, 'client');
    } else {
      try {
        path = p.join((await getApplicationSupportDirectory()).path, 'client');
      } on FileSystemException catch (error) {
        throw FileSystemException(
          'support_directory',
          error.path,
          error.osError,
        );
      }
    }
    final directory = Directory(path);
    await directory.create(recursive: true);
    return Directory(await directory.resolveSymbolicLinks());
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Directory>(
    future: root,
    builder: (context, result) {
      if (!result.hasData) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: Center(
              child: result.hasError
                  ? ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 640),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              '无法打开默认资料目录',
                              style: TextStyle(fontSize: 24),
                            ),
                            const SizedBox(height: 12),
                            SelectableText(
                              '诊断：${startupFailureCode(result.error!)}\n${result.error is FileSystemException ? (result.error as FileSystemException).path : ''}',
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              '未改动已有资料。不需要管理员运行，也不会自动修改 Windows 文件权限。',
                            ),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: () => _retry(),
                              child: const Text('重试默认目录'),
                            ),
                            if (Platform.isWindows || Platform.isLinux) ...[
                              const SizedBox(height: 8),
                              OutlinedButton(
                                onPressed: () => _retry(portable: true),
                                child: const Text('使用程序旁的便携资料目录'),
                              ),
                              const Text(
                                '新资料存入 exe 旁的 zaizuo-data。请将整个程序解压到自己可写的文件夹；已有资料不会自动迁移。不要在共享或临时目录存放真实账户。',
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  : const CircularProgressIndicator(),
            ),
          ),
        );
      }
      return ClientApp(
        root: result.data!,
        navigatorKey: navigatorKey,
        gitFactory: _gitFactory,
        configureGit: _configureGit,
        restoreGit: _restoreGit,
        onDeveloperTools: () => navigatorKey.currentState?.push(
          MaterialPageRoute<void>(
            builder: (routeContext) =>
                MobileProbe(onClose: () => Navigator.of(routeContext).pop()),
          ),
        ),
      );
    },
  );
}
