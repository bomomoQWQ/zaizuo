import 'dart:io';
import 'dart:typed_data';

import 'package:zaizuo_core/zaizuo_core.dart';
// Deliberately avoid the runtime barrel (Node/OneBot) in this offline shell.
import 'package:zaizuo_runtime/src/local_profile.dart';

const probeMaxBytes = 8 * 1024 * 1024;

class ProbeResult {
  const ProbeResult({
    required this.inputBytes,
    required this.webpBytes,
    required this.width,
    required this.height,
    required this.cipherHash,
    required this.preview,
  });
  final int inputBytes;
  final int webpBytes;
  final int width;
  final int height;
  final String cipherHash;
  final Uint8List preview;
}

/// Only app-private throwaway test material. This is not secure-storage or
/// Android Git integration. No user-entered production account is accepted.
class ProbeService {
  ProbeService(Directory privateRoot) : root = privateRoot;
  final Directory root;
  LocalProfile? _profile;

  Future<void> initialize() async {
    await root.create(recursive: true);
    final credential = File('${root.path}/probe-local-password');
    final profileDirectory = Directory('${root.path}/test-profile');
    final String password;
    if (await credential.exists()) {
      password = await credential.readAsString();
      if (password.length > 256) throw StateError('invalid_local_fixture');
    } else {
      // Test-only local password, stored beside its factor. This deliberately
      // makes no production second-factor/Keystore claim.
      password = 'Zx!${hexEncode(secureBytes(24))}Q';
      await credential.writeAsString(password, flush: true);
    }
    if (!await profileDirectory.exists()) {
      await LocalProfile.initialize(
        profileDirectory,
        name: 'probe_local',
        displayName: '本机测试资料',
        password: password,
        parameters: const KdfParameters(
          memoryKiB: 8192,
          iterations: 1,
          parallelism: 1,
        ),
      );
    }
    _profile = await LocalProfile.open(profileDirectory, password);
  }

  Future<ProbeResult> roundTrip(List<int> source) async {
    if (_profile == null) throw StateError('profile_not_initialized');
    if (source.isEmpty || source.length > probeMaxBytes) {
      throw StateError('input_limit');
    }
    final encoder = PreferredImageEncoder(
      lossless: true,
      maxInputBytes: probeMaxBytes,
      maxOutputBytes: probeMaxBytes,
      maxPixels: 4 * 1024 * 1024,
      maxDimension: 4096,
      timeout: const Duration(seconds: 30),
    );
    final compressed = await encoder.encodeBytes(source);
    final dimensions = readImageDimensions(
      compressed,
      maxPixels: 4 * 1024 * 1024,
      maxDimension: 4096,
    );
    if (dimensions.format != 'webp') throw StateError('not_webp');
    final objects = EncryptedAttachments(
      Directory('${root.path}/cipher-objects'),
      maxBytes: probeMaxBytes,
    );
    final key = ConversationKey.generate('mobile-probe-local-only', 1);
    final descriptor = await objects.put(
      compressed,
      key,
      name: 'probe.webp',
      mime: 'image/webp',
    );
    // Read through a fresh instance, not from the encode buffer. put/get
    // validate AEAD, ciphertext digest, plaintext digest and decoded size.
    final reopened = EncryptedAttachments(
      objects.root,
      maxBytes: probeMaxBytes,
    );
    final clear = await reopened.get(descriptor, key);
    if (!equalBytes(clear, compressed)) throw StateError('roundtrip_mismatch');
    final wrong = ConversationKey.generate(key.conversationId, key.epoch);
    var wrongKeyRejected = false;
    try {
      await reopened.get(descriptor, wrong);
    } catch (_) {
      wrongKeyRejected = true;
    }
    if (!wrongKeyRejected) throw StateError('wrong_key_not_rejected');
    return ProbeResult(
      inputBytes: source.length,
      webpBytes: clear.length,
      width: dimensions.width,
      height: dimensions.height,
      cipherHash: descriptor.objectId,
      preview: Uint8List.fromList(clear),
    );
  }

  /// Image round-trip remains independent of the explicitly configured Git node.
  String get gitStatus => '图片往返不联网；未配置 Git 时不会远程访问。\n嵌入式 Git 的真实配置/状态见下方手动测试区。';
}
