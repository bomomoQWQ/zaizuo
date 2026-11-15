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
import 'git_credentials.dart';
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

  Future<GitSync> _androidGit(
    LocalProfile profile,
    String remote,
    Directory dir,
  ) async {
    // PAT is supplied explicitly through the client credential dialog.
    // Username is local configuration, never read from host helpers or environment.
    final scopeFile = File(
      p.join(profile.root.parent.path, 'android-git-scope.json'),
    );
    Map<String, dynamic>? scope;
    if (await scopeFile.exists()) {
      if (await scopeFile.length() > 8192) {
        throw const GitSyncException('invalid_credentials', '本机凭据范围无效');
      }
      scope = jsonObject(await scopeFile.readAsString());
    }
    if (scope == null ||
        scope['repo'] != GitCredentialScope.canonicalRepo(remote)) {
      final username = TextEditingController();
      final token = TextEditingController();
      final context = navigatorKey.currentContext;
      if (context == null)
        throw const GitSyncException('credentials_required', '需要凭据');
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Git HTTPS 凭据'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('仅用于指定测试仓库。PAT 经 Android Keystore 加密保存在本机。'),
              TextField(
                controller: username,
                decoration: const InputDecoration(labelText: '用户名'),
              ),
              TextField(
                controller: token,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '最小权限 PAT'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存并连接'),
            ),
          ],
        ),
      );
      try {
        if (accepted != true)
          throw const GitSyncException('credentials_required', '未提供凭据');
        final selected = GitCredentialScope(remote, username.text.trim());
        await const AndroidGitCredentialStore().save(selected, token.text);
        scope = {'repo': selected.repoUrl, 'username': selected.username};
        await scopeFile.writeAsString(canonicalJson(scope), flush: true);
      } finally {
        token.clear();
        token.dispose();
        username.dispose();
      }
    }
    final credentialScope = GitCredentialScope(
      readString(scope, 'repo'),
      readString(scope, 'username'),
    );
    if (credentialScope.repoUrl != GitCredentialScope.canonicalRepo(remote)) {
      throw const GitSyncException('invalid_credentials', '凭据未绑定此仓库');
    }
    final token = await const AndroidGitCredentialStore().read(credentialScope);
    final backend = EmbeddedGitBackend(
      bundledCaPath: await EmbeddedGitBackend.initializeAndroidCertificates(),
      credential: GitHttpsCredential(
        repositoryUrl: remote,
        username: credentialScope.username,
        personalAccessToken: token,
      ),
    );
    return GitSync.initializeWithBackend(
      backend: backend,
      worktree: dir,
      remoteUrl: remote,
      deviceId: profile.device.certificate!.id,
    );
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
        gitFactory: Platform.isAndroid ? _androidGit : null,
        onDeveloperTools: () => navigatorKey.currentState?.push(
          MaterialPageRoute<void>(builder: (_) => const MobileProbe()),
        ),
      );
    },
  );
}
