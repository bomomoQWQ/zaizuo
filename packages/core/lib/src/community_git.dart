import 'dart:io';

import 'config.dart';
import 'git_sync.dart';

/// Root-signed public community configuration on main, separate from device
/// event branches. The externally verified root fingerprint is mandatory.
///
/// This layer never accepts private keys, passwords, or Git credentials. It
/// transports already signed manifests; settings.devices/keys remain public
/// certificate / encrypted key-envelope metadata interpreted by the runtime.
class CommunityGit {
  final GitSync repository;
  final String pinnedFingerprint;
  final bool _ownsRepository;

  CommunityGit({required this.repository, required this.pinnedFingerprint})
      : _ownsRepository = false {
    _validateFingerprint(pinnedFingerprint);
  }

  CommunityGit._(this.repository, this.pinnedFingerprint)
      : _ownsRepository = true;

  static Future<CommunityGit> initialize({
    required Directory worktree,
    required String remoteUrl,
    required String deviceId,
    required String pinnedFingerprint,
    String gitExecutable = 'git',
  }) async {
    _validateFingerprint(pinnedFingerprint);
    final repository = await GitSync.initialize(
        worktree: worktree,
        remoteUrl: remoteUrl,
        deviceId: deviceId,
        gitExecutable: gitExecutable);
    return CommunityGit._(repository, pinnedFingerprint);
  }

  /// Returns null only when main has never been seen and does not exist yet.
  /// A previously checkpointed main disappearing is an error, not null.
  Future<CommunityManifest?> pull() async {
    final history = await readHistory();
    return history.isEmpty ? null : history.last;
  }

  /// Verifies every revision from 1, never just the latest signature.
  Future<List<CommunityManifest>> readHistory() =>
      repository.readManifests(pinnedFingerprint: pinnedFingerprint);

  /// Returns 1 for a new signed revision, 0 for its identical retry.
  Future<int> publish(CommunityManifest manifest) => repository
      .publishManifest(manifest, pinnedFingerprint: pinnedFingerprint);

  /// A borrowed repository remains open for its content sync owner.
  Future<void> close() async {
    if (_ownsRepository) await repository.close();
  }

  static void _validateFingerprint(String fingerprint) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint)) {
      throw ArgumentError('需要仓库外验证并固定的社区根指纹');
    }
  }
}
