import 'package:zaizuo_core/zaizuo_core.dart';

import 'git_config_store.dart';
import 'git_token_store.dart';

typedef ReadGitToken = Future<String?> Function({
  required String repositoryUrl,
  required String username,
});
typedef SaveGitToken = Future<void> Function({
  required String repositoryUrl,
  required String username,
  required String token,
});
typedef DeleteGitToken = Future<void> Function({
  required String repositoryUrl,
  required String username,
});

/// Binding policy only: no platform storage, controller, network, or UI ownership.
/// The configure callback must return false when its controller reports failure.
class GitBindingService {
  GitBindingService({
    required this.loadConfig,
    required this.saveConfig,
    required this.clearConfig,
    required this.readToken,
    required this.saveToken,
    required this.deleteToken,
    required this.connect,
    required this.disconnect,
  });

  final Future<GitConfig?> Function() loadConfig;
  final Future<void> Function(GitConfig) saveConfig;
  final Future<void> Function() clearConfig;
  final ReadGitToken readToken;
  final SaveGitToken saveToken;
  final DeleteGitToken deleteToken;
  final Future<bool> Function(String remote, GitHttpsToken? credential) connect;
  final Future<bool> Function() disconnect;

  static String _tokenErrorCode(String code) =>
      const {
        'credential_unsupported',
        'credential_invalid_scope',
        'credential_invalid_input',
        'credential_corrupt',
        'credential_invalidated',
        'credential_unavailable',
      }.contains(code)
      ? code
      : 'credential_unavailable';

  static Future<T> _credentials<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on GitTokenStoreException catch (error) {
      throw GitSyncException(_tokenErrorCode(error.code), '本机令牌存储不可用');
    } on ArgumentError {
      throw const GitSyncException('invalid_credentials', 'HTTPS地址、用户名或令牌格式无效');
    } on FormatException {
      throw const GitSyncException('credential_corrupt', '本机令牌不可用');
    }
  }

  /// A remembered binding must never silently fall back to a host helper.
  /// remember=false deliberately does not read any previously retained secret.
  static Future<GitHttpsToken?> credentialForRestore(
    GitConfig config,
    ReadGitToken readToken,
  ) => _credentials(() async {
    if (!config.remember) return null;
    final secret = await readToken(
      repositoryUrl: config.remote,
      username: config.username,
    );
    if (secret == null || secret.isEmpty) {
      throw const GitSyncException('credentials_required', '此范围无可用的已保存令牌');
    }
    return GitHttpsToken(
      repoUrl: config.remote,
      username: config.username,
      token: secret,
    );
  });

  Future<bool> restore() async {
    final config = await loadConfig();
    if (config == null) return false;
    final credential = await credentialForRestore(config, readToken);
    return connect(config.remote, credential);
  }

  Future<bool> configure({
    required String remote,
    required String username,
    String? token,
    required bool remember,
    required bool useSaved,
  }) => _credentials(() async {
    if (remote.trim().isEmpty || username.trim().isEmpty) {
      throw const GitSyncException('invalid_credentials', '缺少仓库地址或用户名');
    }
    // An empty field means no newly supplied token, never an empty credential.
    final supplied = token != null && token.isNotEmpty;
    final usingSaved = !supplied && useSaved;
    final GitHttpsToken? credential;
    if (usingSaved) {
      credential = await credentialForRestore(
        GitConfig(remote: remote, username: username, remember: true),
        readToken,
      );
    } else {
      credential = supplied
          ? GitHttpsToken(repoUrl: remote, username: username, token: token)
          : null;
    }
    if (supplied && remember) {
      await saveToken(repositoryUrl: remote, username: username, token: token);
    }
    if (!await connect(remote, credential)) return false;
    try {
      await saveConfig(
        GitConfig(
          remote: remote,
          username: username,
          // Selecting an existing secret also opts into restoring that binding.
          remember: usingSaved || (supplied && remember),
        ),
      );
    } catch (_) {
      // Connection can succeed while this non-secret convenience write fails.
      throw const GitSyncException(
        'git_binding_write_failed',
        'Git已连接，但绑定未能保存',
      );
    }
    return true;
  });

  Future<bool> forget({
    required String remote,
    required String username,
  }) => _credentials(() async {
    // The persisted scope wins over any edits in the form.
    final config = await loadConfig();
    final scopeRemote = config?.remote ?? remote;
    final scopeUsername = config?.username ?? username;
    if (scopeRemote.trim().isEmpty || scopeUsername.trim().isEmpty) {
      throw const GitSyncException('credentials_required', '没有可删除的凭据范围');
    }
    // Missing credentials are not deletion success. A saved binding still
    // authorizes removing its corrupt/unreadable credential without decrypting
    // it; deleteToken must itself validate and report any storage failure.
    try {
      final secret = await readToken(
        repositoryUrl: scopeRemote,
        username: scopeUsername,
      );
      if (secret == null || secret.isEmpty) {
        throw const GitSyncException('credentials_required', '此范围无已保存令牌');
      }
    } on GitTokenStoreException {
      if (config == null) rethrow;
    } on FormatException {
      if (config == null) rethrow;
    }
    if (!await disconnect()) return false;
    await deleteToken(repositoryUrl: scopeRemote, username: scopeUsername);
    if (config != null) {
      try {
        await clearConfig();
      } catch (_) {
        throw const GitSyncException(
          'git_binding_clear_failed',
          '令牌已删除，但绑定未能清除',
        );
      }
    }
    return true;
  });
}
