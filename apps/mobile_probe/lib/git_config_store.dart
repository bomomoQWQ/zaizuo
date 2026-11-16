import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// Non-secret Git binding. Credentials belong in the platform credential store,
/// never in the remote URL or this convenience file.
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
    : _root = Directory(p.normalize(p.absolute(root.path)));

  final Directory _root;
  File get _file => File(p.join(_root.path, 'git-config.json'));
  static const _maxBytes = 8192;
  static final _random = Random.secure();
  static final _controls = RegExp(r'[\x00-\x20\x7f]');

  static bool _validRemote(String value) {
    if (value.isEmpty ||
        value.length > 2048 ||
        value.trim() != value ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      return false;
    }
    // Local absolute paths are opaque filesystem paths, not URLs. In
    // particular, preserve Windows separators and do not URI-decode them.
    if (value.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) {
      return true;
    }
    if (_controls.hasMatch(value)) return false;
    if (!value.startsWith('https://') && !value.startsWith('ssh://')) {
      return false;
    }
    // Check raw spelling before Uri parsing can normalize dot segments.
    if (RegExp(r'[\\%?#]').hasMatch(value)) return false;
    final authorityStart = value.indexOf('://') + 3;
    final slash = value.indexOf('/', authorityStart);
    final authority = value.substring(
      authorityStart,
      slash < 0 ? value.length : slash,
    );
    final path = slash < 0 ? '' : value.substring(slash);
    if (path.split('/').any((part) => part == '.' || part == '..')) {
      return false;
    }
    if (value.startsWith('https://') && authority.contains('@')) return false;
    if (value.startsWith('ssh://') && authority.contains('@')) {
      final parts = authority.split('@');
      if (parts.length != 2 ||
          !RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$').hasMatch(parts[0])) {
        return false;
      }
    }
    try {
      final uri = Uri.parse(value);
      return uri.hasAuthority &&
          uri.host.isNotEmpty &&
          !uri.host.startsWith('-') &&
          RegExp(r'^[A-Za-z0-9.\-:\[\]]+$').hasMatch(uri.host) &&
          (!uri.hasPort || (uri.port > 0 && uri.port <= 65535));
    } catch (_) {
      return false;
    }
  }

  static bool _validUsername(String value) =>
      value.length <= 256 && !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);

  // Dart's portable IO API has no openat/O_NOFOLLOW directory handles. These
  // checks reject existing links (including ancestors), but are not a claim of
  // protection against an attacker concurrently replacing directory entries.
  Future<bool> _checkRoot({bool create = false}) async {
    final ancestors = <String>[];
    var current = _root.path;
    while (true) {
      ancestors.add(current);
      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }
    for (final path in ancestors.reversed) {
      var type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        if (!create) return false;
        await Directory(path).create();
        type = await FileSystemEntity.type(path, followLinks: false);
      }
      if (type != FileSystemEntityType.directory) {
        throw const FileSystemException('unsafe_git_binding_path');
      }
    }
    return true;
  }

  Future<FileSystemEntityType> _checkFile() async {
    final type = await FileSystemEntity.type(_file.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const FileSystemException('unsafe_git_binding_path');
    }
    return type;
  }

  /// Presence is separate from validity: a corrupt file still exists.
  Future<bool> exists() async {
    try {
      if (!await _checkRoot()) return false;
      return await FileSystemEntity.type(_file.path, followLinks: false) !=
          FileSystemEntityType.notFound;
    } catch (_) {
      return false;
    }
  }

  Future<GitConfig?> load() async {
    RandomAccessFile? handle;
    try {
      if (!await _checkRoot() ||
          await _checkFile() == FileSystemEntityType.notFound) {
        return null;
      }
      handle = await _file.open();
      // Never read an unbounded file, even if it grows after a metadata check.
      final bytes = await handle.read(_maxBytes + 1);
      if (bytes.length > _maxBytes) return null;
      await _checkRoot();
      await _checkFile();
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic> ||
          value.length != 4 ||
          value['version'] != 1) {
        return null;
      }
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
      return null;
    } finally {
      try {
        await handle?.close();
      } catch (_) {
        // No input, path or OS diagnostic is exposed by this convenience store.
      }
    }
  }

  Future<void> save(GitConfig config) async {
    if (!_validRemote(config.remote) || !_validUsername(config.username)) {
      throw const FormatException('invalid_git_binding');
    }
    final bytes = utf8.encode(
      '${jsonEncode({'version': 1, 'remote': config.remote, 'username': config.username, 'remember': config.remember})}\n',
    );
    if (bytes.length > _maxBytes) {
      throw const FormatException('invalid_git_binding');
    }
    File? ownedTemporary;
    try {
      await _checkRoot(create: true);
      await _checkFile();
      for (var attempt = 0; attempt < 8; attempt++) {
        final nonce = List.generate(
          24,
          (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        final candidate = File(p.join(_root.path, '.git-config-$nonce.tmp'));
        try {
          await candidate.create(exclusive: true);
          ownedTemporary = candidate;
          break;
        } on FileSystemException {
          if (await FileSystemEntity.type(candidate.path, followLinks: false) ==
              FileSystemEntityType.notFound) {
            rethrow;
          }
        }
      }
      if (ownedTemporary == null) {
        throw const FileSystemException('git_binding_write_failed');
      }
      await _checkRoot();
      if (await FileSystemEntity.type(
            ownedTemporary.path,
            followLinks: false,
          ) !=
          FileSystemEntityType.file) {
        throw const FileSystemException('unsafe_git_binding_path');
      }
      await ownedTemporary.writeAsBytes(bytes, flush: true);
      await _checkRoot();
      await _checkFile();
      // Same-directory rename replaces the old binding without deleting it first.
      await ownedTemporary.rename(_file.path);
      ownedTemporary = null;
    } catch (_) {
      throw const FileSystemException('git_binding_write_failed');
    } finally {
      if (ownedTemporary != null) {
        try {
          if (await _checkRoot() &&
              await FileSystemEntity.type(
                    ownedTemporary.path,
                    followLinks: false,
                  ) ==
                  FileSystemEntityType.file) {
            await ownedTemporary.delete();
          }
        } catch (_) {
          // Only this invocation's exclusively created temporary is eligible.
        }
      }
    }
  }

  Future<void> clear() async {
    try {
      if (!await _checkRoot()) return;
      if (await _checkFile() == FileSystemEntityType.file) await _file.delete();
    } catch (_) {
      throw const FileSystemException('git_binding_clear_failed');
    }
  }
}
