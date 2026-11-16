import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';
import 'package:zaizuo_runtime/zaizuo_runtime.dart';

typedef GitFactory = Future<GitSync> Function(
  LocalProfile profile,
  String remote,
  Directory dir,
);

/// 测试前端适配层；身份、授权、加密与同步全部复用 runtime。
/// UI 写操作失败通过 [error] 报告，成功仅表示本机持久化，不代表送达。
class ClientController extends ChangeNotifier {
  final Directory root;
  final KdfParameters parameters;
  final GitFactory? gitFactory;
  ZaizuoNode? node;
  bool busy = false;
  String? error;
  String notice = '';
  String? selectedConversationId;
  StreamSubscription<NodeChange>? _changes;
  StreamSubscription<String>? _errors;
  Future<void> _tail = Future.value();
  Future<void>? _shutdown;
  bool _stopping = false;
  bool _disposed = false;
  int _pending = 0;
  String? _remote;

  ClientController(this.root, {KdfParameters? parameters, this.gitFactory})
    : parameters = parameters ?? const KdfParameters();

  LocalProfile? get profile => node?.profile;
  bool get isOpen => node != null && !node!.isClosed;
  bool get admitted =>
      isOpen &&
      profile!.trust.devices.containsKey(profile!.device.certificate!.id);
  String get ownerId => profile?.identity.public.accountId ?? '';
  String get displayName => profile?.displayName ?? '';
  String get name => profile?.identity.public.name ?? '';
  String get communityId => profile?.manifest.communityId ?? '';
  String? get gitRemote => _remote;
  Directory get _profileDirectory => Directory('${root.path}/profile');

  List<ConversationRecord> get conversations {
    if (!admitted) return const [];
    final service = node!.replica.service;
    return service.conversations(actor: service.actor(ownerId));
  }

  ConversationRecord? get selectedConversation => conversations
      .where((item) => item.id == selectedConversationId)
      .firstOrNull;

  List<MessageRecord> get messages {
    final selected = selectedConversation;
    if (selected == null) return const [];
    final service = node!.replica.service;
    return service.messages(
      actor: service.actor(ownerId),
      conversationId: selected.id,
      limit: 100,
    );
  }

  List<SpaceRecord> get spaces {
    if (!admitted) return const [];
    final service = node!.replica.service;
    return service.discoverSpaces(actor: service.actor(ownerId));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Binding/secure-storage failures must not prevent viewing local messages or
  /// silently select a different credential source. Only allowlisted codes are
  /// rendered; arbitrary diagnostics and secret values never enter the UI.
  void reportGitConfigurationError(String code) {
    error = _safeError(GitSyncException(code, '')).message;
    _notify();
  }

  /// 连续点击排队，不丢弃操作；close 必须等此前全部文件写入完成。
  Future<T> _queue<T>(Future<T> Function() action) {
    if (_stopping) {
      return Future.error(const DomainException('closed', '客户端已关闭 [closed]'));
    }
    _pending++;
    busy = true;
    _notify();
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      error = null;
      notice = '';
      try {
        result.complete(await action());
      } catch (cause) {
        final safe = _safeError(cause);
        error = safe.message;
        result.completeError(safe);
      } finally {
        _pending--;
        busy = _pending != 0;
        _notify();
      }
    });
    return result.future;
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await _queue(action);
    } on DomainException {
      // 错误已写入 error；UI 不需要处理未捕获 Future。
    }
  }

  /// Test-only seam: exercises the same error mapping the UI uses.
  @visibleForTesting
  Future<T> queueForTest<T>(Future<T> Function() action) => _queue(action);

  static DomainException _safeError(Object cause) {
    final raw = cause is DomainException
        ? cause.code
        : cause is GitSyncException
        ? cause.code
        : cause is FileSystemException
        ? 'directory_io'
        : cause is StateError
        ? 'state_error'
        : cause is TimeoutException
        ? 'timeout'
        : cause is ArgumentError ||
              cause is RangeError ||
              cause is FormatException
        ? 'invalid_argument'
        : 'operation_failed';
    const labels = <String, String>{
      'bad_request': '输入无效',
      'forbidden': '当前账号没有权限',
      'not_found': '内容不存在或尚未同步',
      'conflict': '内容已存在',
      'quota_exceeded': '已达到资源上限',
      'rate_limited': '操作过于频繁',
      'closed': '客户端已关闭',
      'locked': '请先解锁本机资料',
      'no_conversation': '请先选择会话',
      'unsupported_platform': '此平台尚未配置 Git 同步适配器',
      'git_failed': 'Git 同步失败，请检查仓库与凭据',
      'git_path_too_long': '本机Git路径过长，未完成同步；请保留资料并检查客户端版本和存放路径',
      'remote_gateway_failed': 'Git服务或本地代理返回网关错误（502/503），已尝试HTTP/1.1仍失败',
      'authentication_failed': 'Git认证失败，请检查令牌是否有效',
      'permission_denied': '令牌没有此仓库所需的访问或写入权限',
      'repository_unavailable': '仓库不存在或当前身份不可见',
      'network_unavailable': '无法连接Git服务器，请检查网络',
      'tls_failed': 'Git服务器TLS证书验证失败',
      'credentials_required': '没有找到此仓库已保存的令牌',
      'invalid_credentials': '令牌或用户名格式、仓库绑定无效',
      'credential_unsupported': '此平台不支持安全保存令牌；可改用仅本次输入',
      'credential_invalid_scope': '仓库地址或用户名不符合令牌范围要求',
      'credential_invalid_input': '令牌格式无效',
      'credential_corrupt': '本机保存的令牌已损坏，请重新输入',
      'credential_invalidated': '本机保存的令牌已失效，请重新输入',
      'credential_unavailable': '本机安全存储暂时不可用，未改用系统凭据；请重新输入令牌',
      'git_binding_write_failed': 'Git绑定未能保存；账号资料仍保留，请检查本机存储后重试',
      'git_binding_clear_failed': 'Git绑定未能清除；请核对本机存储，不能视为已忘记配置',
      'invalid_remote': 'Git 仓库地址无效',
      'unmanaged_repository': '同步目录不是受管空目录',
      'repository_identity': '同步目录身份不匹配',
      'invalid_manifest_tree':
          '远端main不是在座社区仓库（可能只有README或其他文件）；请选空仓库，已有社区须导入社区资料并核对指纹。不会覆盖远端',
      'invalid_manifest': '远端社区配置格式无效，已停止同步；请核对仓库，不会覆盖远端',
      'manifest_conflict': '远端社区配置与本机不一致，拒绝覆盖；请核对社区资料与指纹',
      'manifest_gap': '远端缺少连续的社区配置历史，已停止同步',
      'manifest_rewrite': '远端已验收的社区配置被修改或回退，拒绝同步',
      'community_mismatch': '此同步目录属于另一个社区，请核对仓库及社区指纹',
      'community_fingerprint_mismatch':
          '仓库属于另一社区：根指纹与本机不匹配。已停止同步，不会覆盖；加入已有社区需导入其公开配置并核对指纹',
      'invalid_manifest_signature': '远端社区签名或版本链验证失败，已停止同步；请勿重新钉住或强制覆盖',
      'remote_rewrite': '远端分支被回退或分叉，拒绝同步；不要删除本机信任记录',
      'remote_deleted': '已确认的远端分支被删除，须显式核对后恢复',
      'local_fork': '本机与远端历史分叉，拒绝强制覆盖',
      'missing_pins': '本机同步信任记录缺失，拒绝重新信任远端；请保留资料并核对恢复',
      'invalid_pins': '本机同步信任记录无效，已停止同步',
      'missing_checkpoint': '本机社区检查点缺失，已停止同步；请勿删除资料以绕过检查',
      'invalid_checkpoint': '本机社区检查点无效，已停止同步',
      'unsafe_configuration': '受管Git配置或hooks已变化，拒绝执行；请核对本机同步目录',
      'credential_remote_mismatch': '令牌未绑定此仓库地址，已拒绝发送',
      'push_not_observed': '推送后未能从远端确认内容，尚不能确认同步成功',
      'git_unavailable': '无法启动系统Git，请确认已安装Git',
      'invalid_account_name': '账户名须为1–14位英文字母、数字或下划线',
      'invalid_display_name': '显示名称须为1–14个显示字符',
      'invalid_password': '密码须为12–1024位、含大写和小写字母、不能含账户名或常见弱模式',
      'profile_exists': '此目录已有账号资料，请切换到解锁，不要重复创建',
      'incomplete_profile': '上次创建留下了不完整资料，已保留原文件；请选择新的空数据目录再创建',
      'directory_io': '本地数据写入失败，请检查可用空间与目录访问情况',
      'state_error': '客户端状态异常，请锁定后重试或重启程序',
      'timeout': '操作超时，请稍后重试',
      'invalid_argument': '本机数据或参数格式不符合预期',
      'operation_failed': '操作失败，请检查输入、密码或本机状态',
    };
    final code = labels.containsKey(raw) ? raw : 'operation_failed';
    // Only the fallback carries the runtime type: it is a bounded identifier and
    // never includes messages, paths, URLs or secrets.
    final suffix = code == 'operation_failed' ? ' (${cause.runtimeType})' : '';
    return DomainException(code, '${labels[code]} [$code]$suffix');
  }

  ZaizuoNode _requireNode() {
    if (!isOpen) throw const DomainException('locked', '');
    return node!;
  }

  Future<void> _attach(LocalProfile profile, {GitSync? git}) async {
    final opened = await ZaizuoNode.open(
      profile: profile,
      git: git,
      ownsGit: true,
    );
    node = opened;
    _changes = opened.changes.listen((_) {
      if (selectedConversation == null) selectedConversationId = null;
      _notify();
    });
    _errors = opened.errors.listen((code) {
      error = _safeError(DomainException(code, '')).message;
      _notify();
    });
    // 不自动启动 OneBot、中继或后台联网；用户通过同步按钮显式触发。
  }

  Future<void> _detach() async {
    final old = node;
    node = null;
    await _changes?.cancel();
    await _errors?.cancel();
    _changes = null;
    _errors = null;
    await old?.close();
  }

  Future<void> create({
    required String name,
    required String displayName,
    required String password,
    String? communityJson,
    String? fingerprint,
  }) => _run(() async {
    if (isOpen) throw const DomainException('conflict', '');
    // Validate before LocalProfile writes any public files or generates keys.
    // Never expose arbitrary exceptions or echo the supplied password.
    try {
      normalizeAccountName(name);
    } on FormatException {
      throw const DomainException('invalid_account_name', '');
    }
    try {
      validateDisplayName(displayName);
    } on FormatException {
      throw const DomainException('invalid_display_name', '');
    }
    try {
      validatePassword(name, password);
    } on FormatException {
      throw const DomainException('invalid_password', '');
    }
    if (await _profileDirectory.exists() &&
        !await _profileDirectory.list().isEmpty) {
      final complete =
          await File('${_profileDirectory.path}/account.keybox').exists() &&
          await File('${_profileDirectory.path}/local-private.json').exists() &&
          await File('${_profileDirectory.path}/unlock.factor').exists();
      throw DomainException(
        complete ? 'profile_exists' : 'incomplete_profile',
        '',
      );
    }
    final manifest = communityJson == null || communityJson.trim().isEmpty
        ? null
        : CommunityManifest.fromJson(jsonObject(communityJson));
    await LocalProfile.initialize(
      _profileDirectory,
      name: name,
      displayName: displayName,
      password: password,
      community: manifest,
      pinnedFingerprint: fingerprint,
      parameters: parameters,
    );
    await _attach(await LocalProfile.open(_profileDirectory, password));
    notice = admitted ? '本机资料已创建；消息仅保存在本机' : '资料已创建，请导出加入请求并联系社区创建者';
  });

  Future<void> unlock(String password) => _run(() async {
    if (isOpen) throw const DomainException('conflict', '');
    final opened = await LocalProfile.open(_profileDirectory, password);
    // 验证密码失败不会留下半打开 node。
    await _attach(opened);
    notice = '已解锁本机资料';
  });

  Future<void> lock() => _run(() async {
    await _detach();
    selectedConversationId = null;
    _remote = null;
    notice = '已锁定';
  });

  Future<void> createSpace(String title) => _run(() async {
    final result = await _requireNode().execute(
      operation: 'space.create',
      params: {'id': randomId(), 'title': title.trim(), 'public_channel': true},
    );
    selectedConversationId =
        (result['result'] as Map)['defaultRoomId'] as String;
    notice = '公开频道已保存在本机，尚未确认远端同步';
  });

  Future<void> joinSpace(String id) => _run(() async {
    await _requireNode().execute(
      operation: 'space.join',
      params: {'space': id},
    );
    final room = spaces.where((space) => space.id == id).firstOrNull;
    if (room != null && conversations.any((c) => c.id == room.defaultRoomId)) {
      selectedConversationId = room.defaultRoomId;
    }
    notice = '加入操作已保存在本机';
  });

  void selectConversation(String id) {
    if (_stopping) return;
    if (!conversations.any((item) => item.id == id)) {
      error = _safeError(const DomainException('forbidden', '')).message;
    } else {
      selectedConversationId = id;
      error = null;
    }
    _notify();
  }

  String _conversationId() =>
      selectedConversation?.id ??
      (throw const DomainException('no_conversation', ''));

  Future<void> sendText(String text) => _run(() async {
    if (text.trim().isEmpty) throw const DomainException('bad_request', '');
    await _requireNode().execute(
      operation: 'message.send',
      params: {
        'conversation': _conversationId(),
        'parts': [
          {
            'type': 'text',
            'data': {'text': text},
          },
        ],
      },
    );
    notice = '已保存在本机，不表示对方已收到';
  });

  Future<void> sendImage(Uint8List bytes, String name) {
    final snapshot = Uint8List.fromList(bytes);
    return _run(() async {
      final current = _requireNode();
      final conversation = _conversationId();
      final uploaded = await current.media.upload(
        actorId: ownerId,
        name: name,
        bytes: snapshot,
        purpose: 'image',
      );
      await current.execute(
        operation: 'message.send',
        params: {
          'conversation': conversation,
          'parts': [
            {
              'type': 'image',
              'data': {'file_id': uploaded['file_id']},
            },
          ],
        },
      );
      notice = '图片已加密保存在本机，不表示远端已收到';
    });
  }

  Future<void> sync() => _run(() async {
    final current = _requireNode();
    await current.syncOnce();
    notice = current.git == null ? '本机状态已刷新；尚未配置 Git' : '本轮 Git 同步完成，不代表收件人已收到';
  });

  Future<GitSync> _makeGit(LocalProfile profile, String remote) async {
    final dir = Directory(
      '${root.path}/git-${await objectHash({'remote': remote})}',
    );
    final factory = gitFactory;
    if (factory != null) return factory(profile, remote, dir);
    if (Platform.isAndroid || Platform.isIOS) {
      throw const DomainException('unsupported_platform', '');
    }
    return GitSync.initialize(
      worktree: dir,
      remoteUrl: remote,
      deviceId: profile.device.certificate!.id,
    );
  }

  Future<void> disconnectGit() => _run(() async {
    final saved = _requireNode().profile;
    await _detach();
    _remote = null;
    await _attach(saved);
    notice = '已断开Git，消息仍保存在本机';
  });

  Future<void> configureGit(String remote) => _run(() async {
    final saved = _requireNode().profile;
    if (remote.trim().isEmpty) throw const DomainException('bad_request', '');
    await _detach(); // 同一资料绝不同时打开两个 FileEventStore。
    GitSync? git;
    try {
      git = await _makeGit(saved, remote.trim());
      await _attach(saved, git: git);
      _remote = remote.trim();
    } catch (_) {
      await git?.close();
      _remote = null;
      await _attach(saved); // 失败恢复离线节点，但仍向 UI 报告失败。
      rethrow;
    }
    notice = '已配置独立受管同步目录；请执行同步';
  });

  String exportCommunity() =>
      canonicalJson(_requireNode().profile.manifest.toJson());
  Future<String> exportFingerprint() =>
      _queue(() async => _requireNode().profile.manifest.fingerprint());
  Future<String> exportJoinRequest() => _queue(
    () async => canonicalJson(await _requireNode().profile.joinRequest()),
  );
  Future<void> admit(String json) => _run(() async {
    await _requireNode().admit(jsonObject(json));
    notice = '已在本机接纳社区成员，请同步名册';
  });

  Future<void> addFriend(String target) => _run(() async {
    await _requireNode().execute(
      operation: 'friend.add',
      params: {'target': target},
    );
    notice = '好友关系已保存在本机';
  });
  Future<void> startDirect(String target) => _run(() async {
    final result = await _requireNode().execute(
      operation: 'direct.create',
      params: {'target': target},
    );
    selectedConversationId = (result['result'] as Map)['id'] as String;
    notice = '私聊已打开';
  });
  Future<void> registerBot(String name) => _run(() async {
    await _requireNode().execute(
      operation: 'bot.register',
      params: {'id': randomId(), 'display_name': name},
    );
    notice = '机器人已在本机登记；未启动 OneBot 服务';
  });

  Future<List<Map<String, dynamic>>> projectMessage(MessageRecord message) =>
      _queue(
        () async =>
            _requireNode().media.project(actorId: ownerId, message: message),
      );
  Future<Map<String, dynamic>> loadMedia(String fileId) => _queue(
    () async => _requireNode().media.get(actorId: ownerId, fileId: fileId),
  );

  Future<void> shutdown() {
    if (_shutdown != null) return _shutdown!;
    _stopping = true;
    return _shutdown = _tail.then((_) async {
      await _detach();
      selectedConversationId = null;
      busy = false;
      _notify();
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Flutter dispose 不能 await；测试/需立即重开资料的调用者须 await shutdown。
    unawaited(
      shutdown().catchError((Object cause) {
        error = _safeError(cause).message;
      }),
    );
    super.dispose();
  }
}
