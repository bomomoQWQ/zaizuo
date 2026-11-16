import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Non-secret Git binding, stored beside the local profile so an upgraded
/// client reopens the same repository without retyping it.
///
/// Only the remote URL, display username and the "remember token" preference
/// are persisted. The PAT itself never enters this file; when the preference is
/// on, the token is read from the DPAPI/Keystore store instead.
class GitConfig {
  const GitConfig({
    required this.remote,
    required this.username,
    required this.remember,
  });

  final String remote;
  final String username;
  final bool remember;

  @override
  String toString() => 'GitConfig(remote: <redacted>, remember: $remember)';
}

class GitConfigStore {
  GitConfigStore(Directory root)
    : _file = File(p.join(root.path, 'git-config.json'));

  final File _file;
  static const _maxBytes = 8192;

  static bool _validRemote(String value) =>
      value.isNotEmpty &&
      value.length <= 2048 &&
      value.trim() == value &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value) &&
      (value.startsWith('https://') ||
          value.startsWith('ssh://') ||
          value.startsWith('/') ||
          RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value));

  static bool _validUsername(String value) =>
      value.length <= 256 && !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);

  Future<GitConfig?> load() async {
    try {
      if (!await _file.exists()) return null;
      if (await _file.length() > _maxBytes) return null;
      final value = jsonDecode(await _file.readAsString());
      if (value is! Map<String, dynamic> || value['version'] != 1) return null;
      final remote = value['remote'];
      final username = value['username'];
      final remember = value['remember'];
      if (remote is! String ||
          !_validRemote(remote) ||
          username is! String ||
          !_validUsername(username) ||
          remember is! bool) {
        return null;
      }
      return GitConfig(remote: remote, username: username, remember: remember);
    } catch (_) {
      // A damaged convenience file must never block unlocking the profile.
      return null;
    }
  }

  Future<void> save(GitConfig config) async {
    if (!_validRemote(config.remote) || !_validUsername(config.username)) {
      throw const FormatException('invalid_git_binding');
    }
    await _file.parent.create(recursive: true);
    final temporary = File('${_file.path}.tmp');
    await temporary.writeAsString(
      '${jsonEncode({'version': 1, 'remote': config.remote, 'username': config.username, 'remember': config.remember})}\n',
      flush: true,
    );
    await temporary.rename(_file.path);
  }

  Future<void> clear() async {
    if (await _file.exists()) await _file.delete();
  }
}
