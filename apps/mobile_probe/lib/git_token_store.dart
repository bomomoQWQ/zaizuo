import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:zaizuo_core/zaizuo_core.dart' show objectHash;

import 'git_credentials.dart';

/// Fixed diagnostics only. Never contains native errors, paths, or secrets.
class GitTokenStoreException implements Exception {
  const GitTokenStoreException(this.code);
  final String code;
  @override
  String toString() => 'GitTokenStoreException($code)';
}

/// Explicit opt-in storage; callers must obtain user consent before [save].
/// [root] is the profile client root's credentials directory, not a repository.
/// Windows DPAPI uses the current Windows user (not a portable recovery key).
/// Android delegates to the existing Keystore-backed method channel. No other
/// platform falls back to plaintext, host credentials, or subprocesses.
/// Dart Strings cannot be reliably zeroized; callers must not retain/log tokens.
class GitTokenStore {
  GitTokenStore(Directory root)
    : _root = Directory(p.normalize(root.absolute.path));

  final Directory _root;
  static const _maxTokenBytes = 16384;
  static const _maxBlobBytes = 96 * 1024;
  static const _android = AndroidGitCredentialStore();

  GitCredentialScope _scope(String repositoryUrl, String username) {
    try {
      if (username.contains(':')) {
        throw const GitTokenStoreException('credential_invalid_scope');
      }
      return GitCredentialScope(repositoryUrl, username);
    } on GitCredentialException {
      throw const GitTokenStoreException('credential_invalid_scope');
    }
  }

  List<int> _tokenBytes(String token) {
    final bytes = utf8.encode(token);
    if (bytes.isEmpty ||
        bytes.length > _maxTokenBytes ||
        token.codeUnits.any((c) => c < 32 || c == 127) ||
        utf8.decode(bytes) != token) {
      throw const GitTokenStoreException('credential_invalid_input');
    }
    return bytes;
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on GitTokenStoreException {
      rethrow;
    } on GitCredentialException catch (error) {
      const allowed = {
        'credential_invalid_scope',
        'credential_invalid_input',
        'credential_corrupt',
        'credential_invalidated',
        'credential_unavailable',
      };
      throw GitTokenStoreException(
        allowed.contains(error.code) ? error.code : 'credential_unavailable',
      );
    } catch (_) {
      throw const GitTokenStoreException('credential_unavailable');
    }
  }

  void _supported() {
    if (!Platform.isWindows && !Platform.isAndroid) {
      throw const GitTokenStoreException('credential_unsupported');
    }
  }

  Future<void> save({
    required String repositoryUrl,
    required String username,
    required String token,
  }) => _guard(() async {
    final scope = _scope(repositoryUrl, username);
    final bytes = _tokenBytes(token);
    _supported();
    if (Platform.isAndroid) return _android.save(scope, token);
    final cipher = _Dpapi.instance.transform(
      bytes,
      _entropy(scope),
      protect: true,
    );
    final encoded = utf8.encode(
      jsonEncode({
        'version': 1,
        'repo': scope.repoUrl,
        'username': scope.username,
        'ciphertext': base64Encode(cipher),
      }),
    );
    if (encoded.length > _maxBlobBytes) _unavailable();
    await _checkRoot(create: true);
    final file = await _file(scope);
    await _checkFile(file);
    // Exclusive creation prevents a pre-existing path from being followed.
    final random = Random.secure();
    final suffix = List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final temp = File('${file.path}.$suffix.tmp');
    var created = false;
    try {
      await temp.create(exclusive: true);
      created = true;
      await _checkRoot();
      await _checkFile(temp);
      await temp.writeAsBytes(encoded, flush: true);
      await _checkRoot();
      await _checkFile(file);
      await _checkFile(temp);
      // Dart's Windows rename replaces an existing file. Never unlink the old
      // credential first: a failed replacement must preserve the old value.
      await temp.rename(file.path);
      created = false;
    } finally {
      if (created) {
        // Cleanup also refuses a substituted link or changed directory tree.
        try {
          await _checkRoot();
          await _checkFile(temp);
          if (await temp.exists()) await temp.delete();
        } catch (_) {
          /* Do not replace the fixed primary diagnostic. */
        }
      }
    }
  });

  Future<String?> read({
    required String repositoryUrl,
    required String username,
  }) => _guard(() async {
    final scope = _scope(repositoryUrl, username);
    _supported();
    if (Platform.isAndroid) {
      try {
        final token = await _android.read(scope);
        _tokenBytes(token);
        return token;
      } on GitCredentialException catch (error) {
        if (error.code == 'credential_missing') return null;
        rethrow;
      }
    }
    if (!await _checkRoot()) return null;
    final file = await _file(scope);
    if (!await _checkFile(file)) return null;
    // Bound reads even if a file changes after stat; never read an entire
    // attacker-supplied oversized file into memory.
    final input = await file.open();
    late Uint8List data;
    try {
      data = await input.read(_maxBlobBytes + 1);
    } finally {
      await input.close();
    }
    await _checkRoot();
    await _checkFile(file);
    if (data.length > _maxBlobBytes) _unavailable();
    final value = jsonDecode(utf8.decode(data));
    if (value is! Map<String, dynamic> ||
        value.length != 4 ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['repo'] != scope.repoUrl ||
        value['username'] != scope.username ||
        value['ciphertext'] is! String)
      _unavailable();
    final text = value['ciphertext'] as String;
    final cipher = base64Decode(text);
    if (cipher.isEmpty ||
        cipher.length > _maxBlobBytes ||
        base64Encode(cipher) != text)
      _unavailable();
    final plain = _Dpapi.instance.transform(
      cipher,
      _entropy(scope),
      protect: false,
    );
    try {
      final token = utf8.decode(plain);
      _tokenBytes(token);
      return token;
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  });

  Future<void> delete({
    required String repositoryUrl,
    required String username,
  }) => _guard(() async {
    final scope = _scope(repositoryUrl, username);
    _supported();
    if (Platform.isAndroid) return _android.delete(scope);
    if (!await _checkRoot()) return;
    final file = await _file(scope);
    if (await _checkFile(file)) await file.delete();
  });

  List<int> _entropy(GitCredentialScope scope) =>
      utf8.encode('zaizuo.git-token.v1\n${scope.repoUrl}\n${scope.username}');

  Future<File> _file(GitCredentialScope scope) async {
    final hash = await objectHash({
      'domain': 'zaizuo.git-token.v1',
      'repo': scope.repoUrl,
      'username': scope.username,
    });
    return File(p.join(_root.path, '$hash.json'));
  }

  // Check every ancestor without following links, even if root was previously
  // canonicalized. This is not protection against a hostile concurrent process
  // with the same user's rights replacing directories between OS operations.
  Future<bool> _checkRoot({bool create = false}) async {
    final parents = <Directory>[];
    var current = _root;
    while (true) {
      parents.add(current);
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }
    for (final directory in parents.reversed) {
      var type = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) {
        if (!create) return false;
        await directory.create();
        type = await FileSystemEntity.type(directory.path, followLinks: false);
      }
      if (type != FileSystemEntityType.directory) _unavailable();
      final real = p.normalize(await directory.resolveSymbolicLinks());
      if (!p.equals(real, directory.path)) _unavailable();
    }
    return true;
  }

  Future<bool> _checkFile(File file) async {
    if (!p.equals(p.dirname(file.path), _root.path)) _unavailable();
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.file) _unavailable();
    return true;
  }

  @override
  String toString() => 'GitTokenStore(redacted)';
}

Never _unavailable() =>
    throw const GitTokenStoreException('credential_unavailable');

// Native FFI alignment supplies the pointer padding after the DWORD on x64.
final class _DataBlob extends Struct {
  @Uint32()
  external int length;
  external Pointer<Uint8> data;
}

typedef _CryptNative = Int32 Function(
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Pointer<_DataBlob>,
);
typedef _CryptDart = int Function(
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<_DataBlob>,
);
typedef _FreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _FreeDart = Pointer<Void> Function(Pointer<Void>);

class _Dpapi {
  _Dpapi() {
    final crypt32 = DynamicLibrary.open('crypt32.dll');
    _protect = crypt32.lookupFunction<_CryptNative, _CryptDart>(
      'CryptProtectData',
    );
    _unprotect = crypt32.lookupFunction<_CryptNative, _CryptDart>(
      'CryptUnprotectData',
    );
    _free = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<_FreeNative, _FreeDart>('LocalFree');
  }
  static final instance = _Dpapi();
  late final _CryptDart _protect;
  late final _CryptDart _unprotect;
  late final _FreeDart _free;

  Uint8List transform(
    List<int> bytes,
    List<int> entropy, {
    required bool protect,
  }) {
    final input = calloc<_DataBlob>();
    final extra = calloc<_DataBlob>();
    final output = calloc<_DataBlob>();
    Pointer<Uint8> inputBytes = nullptr;
    Pointer<Uint8> entropyBytes = nullptr;
    try {
      inputBytes = calloc<Uint8>(bytes.length);
      entropyBytes = calloc<Uint8>(entropy.length);
      inputBytes.asTypedList(bytes.length).setAll(0, bytes);
      entropyBytes.asTypedList(entropy.length).setAll(0, entropy);
      input.ref
        ..length = bytes.length
        ..data = inputBytes;
      extra.ref
        ..length = entropy.length
        ..data = entropyBytes;
      // CRYPTPROTECT_UI_FORBIDDEN; no LOCAL_MACHINE flag, prompt, description,
      // reserved pointer, subprocess, or process command line.
      final ok = (protect ? _protect : _unprotect)(
        input,
        nullptr,
        extra,
        nullptr,
        nullptr,
        1,
        output,
      );
      if (ok == 0 ||
          output.ref.data == nullptr ||
          output.ref.length == 0 ||
          output.ref.length > (protect ? 96 * 1024 : 16384))
        _unavailable();
      return Uint8List.fromList(output.ref.data.asTypedList(output.ref.length));
    } finally {
      if (output.ref.data != nullptr) {
        if (output.ref.length <= 96 * 1024) {
          output.ref.data
              .asTypedList(output.ref.length)
              .fillRange(0, output.ref.length, 0);
        }
        _free(output.ref.data.cast());
      }
      if (inputBytes != nullptr) {
        inputBytes.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
        calloc.free(inputBytes);
      }
      if (entropyBytes != nullptr) {
        entropyBytes
            .asTypedList(entropy.length)
            .fillRange(0, entropy.length, 0);
        calloc.free(entropyBytes);
      }
      calloc.free(input);
      calloc.free(extra);
      calloc.free(output);
    }
  }
}
