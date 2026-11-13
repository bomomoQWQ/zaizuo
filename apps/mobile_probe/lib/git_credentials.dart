import 'package:flutter/services.dart';

/// Repository-scoped explicit HTTPS credentials. Never uses host helpers,
/// environment, SSH, profile files or Git config. Only Android persists the PAT.
class GitCredentialScope {
  GitCredentialScope(String url, this.username) : repoUrl = canonicalRepo(url) {
    if (username.isEmpty || username.length > 256 || _controls(username)) {
      throw const GitCredentialException('credential_invalid_scope');
    }
  }

  final String repoUrl;
  final String username;

  static String canonicalRepo(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        value != value.trim() ||
        value.length > 4096 ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        value.contains('@') ||
        value.contains('\\') ||
        RegExp(r'/(?:\.|%2[eE])(?:\.|%2[eE])?(?:/|$)').hasMatch(value) ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path.isEmpty ||
        uri.path == '/' ||
        uri.port <= 0 ||
        uri.port > 65535 ||
        _controls(value) ||
        uri.pathSegments.any((part) => part == '.' || part == '..')) {
      throw const GitCredentialException('credential_invalid_scope');
    }
    return uri
        .replace(
          scheme: 'https',
          host: uri.host.toLowerCase(),
          port: uri.port == 443 ? 443 : uri.port,
        )
        .toString();
  }

  Map<String, Object> get arguments => {
    'repoUrl': repoUrl,
    'username': username,
  };
  @override
  String toString() => 'GitCredentialScope(redacted)';
}

bool _controls(String value) => value.codeUnits.any((c) => c < 32 || c == 127);

/// Fixed diagnostics only: never retain native messages/details or PAT values.
class GitCredentialException implements Exception {
  const GitCredentialException(this.code);
  final String code;
  @override
  String toString() => 'GitCredentialException($code)';
}

class AndroidGitCredentialStore {
  const AndroidGitCredentialStore({
    MethodChannel channel = const MethodChannel('zaizuo.mobile_probe/native'),
  }) : _channel = channel;
  final MethodChannel _channel;
  static const _codes = {
    'credential_invalid_scope',
    'credential_invalid_input',
    'credential_missing',
    'credential_corrupt',
    'credential_invalidated',
    'credential_unavailable',
  };

  Future<T?> _invoke<T>(String method, Map<String, Object> args) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (error) {
      throw GitCredentialException(
        _codes.contains(error.code) ? error.code : 'credential_unavailable',
      );
    } catch (_) {
      throw const GitCredentialException('credential_unavailable');
    }
  }

  Future<void> save(GitCredentialScope scope, String token) async {
    if (token.isEmpty || token.length > 16384 || _controls(token)) {
      throw const GitCredentialException('credential_invalid_input');
    }
    await _invoke<void>('gitCredentialSave', {
      ...scope.arguments,
      'token': token,
    });
  }

  /// The returned string exists only in memory for the native Git callback.
  /// Dart Strings cannot be reliably zeroized; callers must not retain/log it.
  Future<String> read(GitCredentialScope scope) async {
    final token = await _invoke<String>('gitCredentialRead', scope.arguments);
    if (token == null || token.isEmpty) {
      throw const GitCredentialException('credential_corrupt');
    }
    return token;
  }

  Future<void> delete(GitCredentialScope scope) async {
    await _invoke<void>('gitCredentialDelete', scope.arguments);
  }
}
