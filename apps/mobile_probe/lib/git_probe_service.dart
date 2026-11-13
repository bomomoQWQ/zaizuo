import 'dart:convert';
import 'dart:io';

import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_git_mobile/git_mobile.dart';
import 'package:zaizuo_runtime/zaizuo_runtime.dart';

import 'git_credentials.dart';

/// Throwaway developer profile with foreground/manual Git only. The local
/// password/factor remain co-located test fixtures, not independent 2FA.
class GitProbeService {
  GitProbeService(this.root);
  final Directory root;
  ZaizuoNode? _node;
  LocalProfile? _profile;
  GitCredentialScope? _scope;
  String get status => _node == null
      ? 'Git 节点未打开（不会自动联网）。'
      : 'Git 已配置；完成手动同步 ${_node!.completedSyncs} 轮；本地事件 ${_node!.store.allEnvelopes.length}；后台同步关闭。';

  Future<void> initialize({String? communityJson, String? fingerprint}) async {
    await close();
    await root.create(recursive: true);
    final passwordFile = File('${root.path}/test-password');
    final directory = Directory('${root.path}/profile');
    String password;
    if (await passwordFile.exists()) {
      password = await passwordFile.readAsString();
    } else {
      password = 'Zx!${hexEncode(secureBytes(24))}Q';
      await passwordFile.writeAsString(password, flush: true);
    }
    if (!await directory.exists()) {
      CommunityManifest? community;
      if (communityJson != null && communityJson.isNotEmpty) {
        if (communityJson.length > 1024 * 1024 ||
            fingerprint == null ||
            fingerprint.isEmpty) {
          throw StateError('invalid_community_fixture');
        }
        community = CommunityManifest.fromJson(
          jsonDecode(communityJson) as Map<String, dynamic>,
        );
        await community.verify(fingerprint);
      }
      await LocalProfile.initialize(
        directory,
        name: 'android_probe_${hexEncode(secureBytes(6))}',
        displayName: 'Android Git 测试资料',
        password: password,
        community: community,
        pinnedFingerprint: fingerprint,
        parameters: const KdfParameters(
          memoryKiB: 8192,
          iterations: 1,
          parallelism: 1,
        ),
      );
    } else if (communityJson != null && communityJson.isNotEmpty) {
      throw StateError('profile_already_exists');
    }
    _profile = await LocalProfile.open(directory, password);
  }

  Future<void> open(GitCredentialScope scope) async {
    final profile = _profile;
    if (profile == null) throw StateError('profile_not_initialized');
    await close();
    final token = await const AndroidGitCredentialStore().read(scope);
    final ca = await EmbeddedGitBackend.initializeAndroidCertificates();
    final backend = EmbeddedGitBackend(
      bundledCaPath: ca,
      credential: GitHttpsCredential(
        repositoryUrl: scope.repoUrl,
        username: scope.username,
        personalAccessToken: token,
      ),
    );
    final repoId = await objectHash({'repo': scope.repoUrl});
    GitSync? git;
    try {
      git = await GitSync.initializeWithBackend(
        backend: backend,
        worktree: Directory('${root.path}/git-$repoId'),
        remoteUrl: scope.repoUrl,
        deviceId: profile.device.certificate!.id,
        maxEvents: 10000,
        maxSegmentBytes: 8 * 1024 * 1024,
        maxDevices: 128,
      );
      _node = await ZaizuoNode.open(profile: profile, git: git, ownsGit: true);
      _scope = scope;
      // Deliberately do NOT call start/startBackgroundSync or create OneBot.
    } catch (_) {
      if (git != null) {
        await git.close();
      } else {
        await backend.close();
      }
      rethrow;
    }
  }

  Future<void> sync() async {
    final node = _node;
    if (node == null) throw StateError('git_not_configured');
    // Detect removed/invalidated credentials before starting a new round.
    await const AndroidGitCredentialStore().read(_scope!);
    await node.syncOnce();
  }

  Future<String> exportCommunity() async {
    final profile = _profile;
    if (profile == null) throw StateError('profile_not_initialized');
    return canonicalJson(profile.manifest.toJson());
  }

  Future<String> exportFingerprint() async {
    final profile = _profile;
    if (profile == null) throw StateError('profile_not_initialized');
    return profile.manifest.fingerprint();
  }

  Future<String> exportJoinRequest() async {
    final profile = _profile;
    if (profile == null) throw StateError('profile_not_initialized');
    return canonicalJson(await profile.joinRequest());
  }

  Future<void> admit(String request) async {
    if (request.length > 1024 * 1024 || _node == null)
      throw StateError('invalid_request');
    await _node!.admit(jsonDecode(request) as Map<String, dynamic>);
  }

  Future<void> sendTestMessage() async {
    final node = _node;
    if (node == null) throw StateError('git_not_configured');
    final state = node.replica.service.state;
    if (!state.bots.containsKey('android-git-probe-bot')) {
      await node.execute(
        operation: 'bot.register',
        params: {
          'id': 'android-git-probe-bot',
          'display_name': 'Android Git Probe',
        },
      );
    }
    if (!state.spaces.containsKey('android-git-probe-space')) {
      await node.execute(
        operation: 'space.create',
        params: {
          'id': 'android-git-probe-space',
          'title': 'Android Git Probe',
          'public_channel': true,
        },
      );
      await node.execute(
        operation: 'space.join',
        params: {
          'space': 'android-git-probe-space',
          'bot_id': 'android-git-probe-bot',
        },
      );
    }
    await node.execute(
      operation: 'space.join',
      params: {'space': 'android-git-probe-space'},
    );
    await node.execute(
      operation: 'message.send',
      params: {
        'conversation': 'android-git-probe-space#main',
        'parts': [
          {
            'type': 'text',
            'data': {'text': 'Android foreground Git probe test message'},
          },
        ],
      },
    );
  }

  Future<void> sendTestAttachment(List<int> bytes) async {
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024)
      throw StateError('input_limit');
    await sendTestMessage();
    final node = _node!;
    final uploaded = await node.media.upload(
      actorId: node.profile.identity.public.accountId,
      name: 'android-probe.png',
      bytes: bytes,
      purpose: 'image',
    );
    await node.execute(
      operation: 'space.join',
      params: {'space': 'android-git-probe-space'},
    );
    await node.execute(
      operation: 'message.send',
      params: {
        'conversation': 'android-git-probe-space#main',
        'parts': [
          {
            'type': 'image',
            'data': {'file_id': uploaded['file_id']},
          },
        ],
      },
    );
  }

  int get messageCount => _node?.replica.service.state.messages.length ?? 0;

  Future<void> close() async {
    final node = _node;
    _node = null;
    _scope = null;
    if (node != null) await node.close();
  }
}
