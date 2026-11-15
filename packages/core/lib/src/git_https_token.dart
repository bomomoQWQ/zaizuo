import 'dart:io';

/// Explicit HTTPS-only credentials for one complete repository URL.
///
/// This value is not persistent storage. Callers own secure storage and must not
/// log its fields. Dart strings cannot be reliably zeroized; dropping references
/// does not promise immediate erasure from managed memory.
class GitHttpsToken {
  final String repoUrl;
  final String username;
  final String token;

  GitHttpsToken({
    required String repoUrl,
    required this.username,
    required this.token,
  }) : repoUrl = canonicalRepoUrl(repoUrl) {
    if (username.isEmpty ||
        username.contains(':') ||
        token.isEmpty ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch('$username$token')) {
      // Never include rejected secret values in exceptions.
      throw ArgumentError('无效HTTPS用户名或令牌');
    }
  }

  /// Validates before URI parsing, which would otherwise remove dot segments.
  /// The same canonicalization is applied to the backend's effective remote.
  static String canonicalRepoUrl(String value) {
    if (value.isEmpty ||
        value.trim() != value ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(value) ||
        value.contains('\\') ||
        value.contains('%') ||
        RegExp(r'^https://[^/]*@', caseSensitive: false).hasMatch(value) ||
        RegExp(r'/\.{1,2}(?:/|$)').hasMatch(value)) {
      throw ArgumentError('需要无凭据的精确HTTPS仓库URL');
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        !uri.hasAuthority ||
        uri.authority.contains('@') ||
        uri.host.isEmpty ||
        !(RegExp(r'^[A-Za-z0-9][A-Za-z0-9.-]*$').hasMatch(uri.host) ||
            InternetAddress.tryParse(uri.host) != null) ||
        uri.port < 1 ||
        uri.port > 65535 ||
        uri.path.isEmpty ||
        uri.path == '/' ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw ArgumentError('需要无凭据的精确HTTPS仓库URL');
    }
    return Uri(
      scheme: 'https',
      host: uri.host.toLowerCase(),
      port: uri.port == 443 ? null : uri.port,
      path: uri.path,
    ).toString();
  }

  @override
  String toString() => 'GitHttpsToken(<redacted>)';
}
