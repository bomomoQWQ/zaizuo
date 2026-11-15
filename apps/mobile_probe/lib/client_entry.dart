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

/// Resolves only local application storage; startup never contacts a remote.
class ClientEntry extends StatefulWidget {
  const ClientEntry({super.key, this.dataDirectory});
  final String? dataDirectory;
  @override
  State<ClientEntry> createState() => _ClientEntryState();
}

class _ClientEntryState extends State<ClientEntry> {
  final navigatorKey = GlobalKey<NavigatorState>();
  late final Future<Directory> root = _root();
  Future<Directory> _root() async {
    String path;
    if (widget.dataDirectory != null) {
      if (!p.isAbsolute(widget.dataDirectory!)) {
        throw StateError('data_directory_must_be_absolute');
      }
      path = widget.dataDirectory!;
    } else if (Platform.isAndroid) {
      final value = await const MethodChannel('zaizuo.mobile_probe/native')
          .invokeMapMethod<String, dynamic>('environment');
      final native = value?['privateRoot'];
      if (native is! String) throw StateError('private_directory_unavailable');
      path = p.join(native, 'client');
    } else {
      path = p.join((await getApplicationSupportDirectory()).path, 'client');
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
                  ? const Text('无法打开本机测试资料目录。请检查目录权限。')
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
