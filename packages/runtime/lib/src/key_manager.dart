import 'dart:convert';

import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';

Never _keyFail(String code, String message) =>
    throw DomainException(code, message);
void _keyRequire(bool value, String code, String message) {
  if (!value) _keyFail(code, message);
}

Map<String, dynamic> _keyObject(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    _keyFail('bad_request', '需要密钥协议 JSON 对象');
  }
  return Map<String, dynamic>.from(value);
}

void _keyFields(Map<String, dynamic> value, Set<String> fields) {
  _keyRequire(
      value.length == fields.length && value.keys.every(fields.contains),
      'bad_request',
      '密钥协议字段缺失或含未知字段');
}

String _keyString(Map<String, dynamic> value, String field, {int max = 512}) {
  final item = value[field];
  _keyRequire(item is String && item.isNotEmpty && item.length <= max,
      'bad_request', '无效密钥字段 $field');
  return item as String;
}

int _keyEpoch(Map<String, dynamic> value) {
  final epoch = value['epoch'];
  _keyRequire(epoch is int && epoch >= 1 && epoch <= 9007199254740991,
      'bad_request', '无效密钥 epoch');
  return epoch as int;
}

/// principal 与加密接收账户分开；bot 使用 owner 的已钉住账号交换公钥。
/// 公告不把只读 owner 冒充为 DM 的发言参与者。
final class KeyAudience {
  final String conversationId;
  final Map<String, String> principalOwnerIds;
  final List<String> authorizationEventIds;
  KeyAudience._(
      this.conversationId, Map<String, String> owners, List<String> ids)
      : principalOwnerIds = Map.unmodifiable(owners),
        authorizationEventIds = List.unmodifiable(ids);
  Set<String> get accountIds => Set.unmodifiable(principalOwnerIds.values);
  String get policyToken => canonicalJson({
        'principals': principalOwnerIds,
        'authorization_events': authorizationEventIds
      });
  Map<String, dynamic> toJson() => {
        'conversation': conversationId,
        'principals': principalOwnerIds,
        'authorization_events': authorizationEventIds
      };
}

/// 任意当期合法持钥成员可签发的无秘密 epoch 公告，不要求社区 owner 在线。
final class KeyEpochAnnouncement {
  final Map<String, dynamic> body;
  final String signature;
  KeyEpochAnnouncement._(Map<String, dynamic> value, this.signature)
      : body = immutableProtocolObject(value);
  factory KeyEpochAnnouncement.fromJson(Map<String, dynamic> json) {
    _keyFields(json, {'body', 'signature'});
    return KeyEpochAnnouncement._(
        _keyObject(json['body']), _keyString(json, 'signature', max: 256));
  }
  String get communityId => body['community'] as String;
  String get conversationId => body['conversation'] as String;
  int get epoch => body['epoch'] as int;
  String get issuerAccountId => body['issuer'] as String;
  String get keyCommitment => body['key_commitment'] as String;
  Map<String, String> get principalOwnerIds =>
      Map.unmodifiable(Map<String, String>.from(body['principals'] as Map));
  Map<String, dynamic> toJson() => {'body': body, 'signature': signature};
}

/// announcement 可经外层 control 加密事件发布；key 仅留本机，不进公告。
final class KeyRotation {
  final ConversationKey key;
  final KeyEpochAnnouncement announcement;
  const KeyRotation._(this.key, this.announcement);
}

/// 除 core 的 recipient 密钥封装签名外，再绑定具体 principal 与 epoch 公告。
/// 外层日志仍须验签、验证通道和重放顺序；这里的签名不替代设备授权。
final class KeyGrant {
  final Map<String, dynamic> body;
  final String signature;
  KeyGrant._(Map<String, dynamic> value, this.signature)
      : body = immutableProtocolObject(value);
  factory KeyGrant.fromJson(Map<String, dynamic> json) {
    _keyFields(json, {'body', 'signature'});
    return KeyGrant._(
        _keyObject(json['body']), _keyString(json, 'signature', max: 256));
  }
  String get conversationId => body['conversation'] as String;
  int get epoch => body['epoch'] as int;
  String get recipientPrincipalId => body['recipient_principal'] as String;
  String get recipientAccountId => body['recipient_account'] as String;
  String get senderAccountId => body['sender'] as String;
  KeyEpochAnnouncement get announcement =>
      KeyEpochAnnouncement.fromJson(_keyObject(body['announcement']));
  Map<String, dynamic> toJson() => {'body': body, 'signature': signature};
}

/// 只读 domain 的密钥授权协调器，不修改成员、审批、caps 或消息状态。
/// trustedAccounts 必须来自外层已钉住/已验证的账户公钥目录，不读信封自报公钥。
final class ConversationKeyManager {
  final ChatService service;
  final String communityId;
  final Map<String, IdentityPublic> trustedAccounts;
  Set<String>? _communityAccountIds;
  Set<String> get communityAccountIds => Set.unmodifiable(
      _communityAccountIds ?? service.state.accounts.keys.toSet());

  /// 仅可信外层按已验签历史manifest revision设置；不得从grant自报列表调用。
  void setCommunityAccounts(Set<String> ids) {
    _keyRequire(
        ids.every((id) =>
            service.state.accounts.containsKey(id) &&
            trustedAccounts.containsKey(id)),
        'bad_request',
        '历史名册上下文含未知或未钉住账户');
    _communityAccountIds = Set.unmodifiable(ids);
  }

  final Map<String, Map<int, KeyEpochAnnouncement>> _epochs = {};
  final Set<String> _conflicts = {};
  Set<String> get conflictedConversations => Set.unmodifiable(_conflicts);

  void _notConflicted(String conversationId) {
    _keyRequire(!_conflicts.contains(conversationId), 'epoch_conflict',
        '该会话已检测epoch分叉；停止生成/分发/接收，须外层可信裁决');
  }

  ConversationKeyManager(
      {required this.service,
      required this.communityId,
      required Map<String, IdentityPublic> trustedAccounts,
      Set<String>? communityAccountIds})
      : trustedAccounts = Map.unmodifiable(trustedAccounts) {
    _keyRequire(communityId.isNotEmpty && communityId.length <= 256,
        'bad_request', '无效社区编号');
    _keyRequire(
        trustedAccounts.entries.every((e) => e.key == e.value.accountId),
        'bad_request',
        '钉住的账户目录索引与身份不匹配');
    if (communityAccountIds != null) setCommunityAccounts(communityAccountIds);
  }

  /// 当前/最新公告，不返回明文密钥。
  KeyEpochAnnouncement? currentAnnouncement(String conversationId) {
    final epochs = _epochs[conversationId];
    if (epochs == null || epochs.isEmpty) return null;
    final max = epochs.keys.reduce((a, b) => a > b ? a : b);
    return epochs[max];
  }

  bool _communityContains(String id) =>
      (_communityAccountIds ?? service.state.accounts.keys.toSet())
          .contains(id);
  bool _active(String id) {
    if (service.state.accounts.containsKey(id)) return _communityContains(id);
    final bot = service.state.bots[id];
    return bot != null &&
        bot.active &&
        !bot.draft &&
        _communityContains(bot.ownerId);
  }

  String _owner(String id) {
    if (service.state.accounts.containsKey(id)) return id;
    return service.state.bots[id]?.ownerId ?? _keyFail('not_found', '会话主体不存在');
  }

  bool _readCap(String id) =>
      service.state.bots[id]?.caps.contains(BotCapability.readHistory) ?? true;

  /// 支持 chat / shadow / forum房间 / forumThread / direct，以及显式 feed scope。
  /// 空间只认当前合法成员，历史 canReadConversation 不能拿来给新 epoch 授权。
  KeyAudience resolveAuthorizedRecipients(String conversationId) {
    final state = service.state;
    _keyRequire(
        conversationId.isNotEmpty &&
            conversationId.length <= 256 &&
            !RegExp(r'\s|[\x00-\x1F\x7F]').hasMatch(conversationId),
        'bad_request',
        '无效会话scope');
    final reserved = conversationId.startsWith('control:') ||
        conversationId.startsWith('feed:');
    _keyRequire(
        !reserved ||
            (!state.conversations.containsKey(conversationId) &&
                !state.rooms.containsKey(conversationId)),
        'forbidden',
        '业务房间/会话与保留scope碰撞，拒绝降级解析');
    _keyRequire(
        !conversationId.startsWith('control:'), 'forbidden', '控制通道不属于会话密钥分发范围');
    final principals = <String, String>{};
    final conversation = reserved ? null : state.conversations[conversationId];
    final room = (reserved ? null : state.rooms[conversationId]) ??
        (conversation?.roomId == null
            ? null
            : state.rooms[conversation!.roomId]);
    String category;
    String? spaceId;
    String? roomId;
    List<String> directIds = const [];
    String? feedAuthorId;
    String? feedAuthorOwner;
    String? feedVisibility;
    if (conversation?.kind == 'direct') {
      category = 'direct';
      directIds = conversation!.participantIds;
      for (final id in directIds) {
        if (_active(id) && _readCap(id)) principals[id] = _owner(id);
      }
      if (directIds.every((id) => state.bots.containsKey(id))) {
        for (final id in directIds) {
          final owner = _owner(id);
          if (_communityContains(owner)) principals[owner] = owner;
        }
      }
    } else if (room != null) {
      category = 'room';
      spaceId = room.spaceId;
      roomId = room.id;
      for (final member in state.memberships.values
          .where((m) => m.spaceId == spaceId && m.status == 'joined')) {
        final id = member.principalId;
        if (!_active(id) || !_readCap(id)) continue;
        final actor = service.actor(id);
        final current = service.rooms(actor: actor, spaceId: spaceId);
        if (!current.any((r) => r.id == roomId)) continue;
        if (conversation?.kind == 'forumThread' &&
            !service.canReadConversation(
                actor: actor, conversationId: conversationId)) continue;
        principals[id] = actor.ownerId;
      }
    } else if (conversationId.startsWith('feed:')) {
      category = 'feed';
      final split = conversationId.lastIndexOf(':');
      _keyRequire(split > 5, 'bad_request', '无效 feed scope');
      final authorId = conversationId.substring(5, split);
      final visibility = conversationId.substring(split + 1);
      feedAuthorId = authorId;
      feedAuthorOwner = _owner(authorId);
      feedVisibility = visibility;
      _keyRequire({'public', 'friends', 'private'}.contains(visibility),
          'bad_request', '未知 feed visibility');
      _keyRequire(_active(authorId), 'forbidden', '朋友圈作者未入驻');
      final author = service.actor(authorId);
      final candidates = <String>{authorId};
      if (visibility == 'public') {
        candidates.addAll(communityAccountIds);
        candidates.addAll(state.bots.values
            .where((bot) => _communityContains(bot.ownerId))
            .map((bot) => bot.id));
      } else if (visibility == 'friends') {
        candidates.addAll(service.friends(actor: author).map((p) => p.id));
      }
      for (final id in candidates) {
        if (_active(id) && _readCap(id)) principals[id] = _owner(id);
      }
    } else {
      _keyFail('not_found', '未知会话范围，不能回退为全社区密钥');
    }
    final sorted = Map<String, String>.fromEntries((principals.keys.toList()
          ..sort())
        .map((id) => MapEntry(id, principals[id]!)));
    final revisions = <String>[];
    bool rows(DomainEvent event, String name,
            bool Function(Map<String, dynamic>) matches) =>
        (event.data[name] as List? ?? const [])
            .any((item) => matches(_keyObject(item)));
    for (final event in state.events) {
      var relevant = false;
      if (category == 'room') {
        relevant = rows(event, 'spaces', (j) => j['id'] == spaceId) ||
            rows(event, 'rooms', (j) => j['id'] == roomId) ||
            rows(event, 'memberships', (j) => j['spaceId'] == spaceId) ||
            rows(event, 'bans',
                (j) => j['scopeId'] == spaceId || j['scopeId'] == roomId) ||
            rows(
                event,
                'bots',
                (j) =>
                    j['draft'] != true &&
                    state.memberships.values.any((m) =>
                        m.spaceId == spaceId && m.principalId == j['id'])) ||
            (conversation?.kind == 'forumThread' &&
                rows(
                    event,
                    'hidden',
                    (j) =>
                        j['kind'] == 'forum' &&
                        j['id'] == conversation!.postId));
      } else if (category == 'direct') {
        relevant =
            rows(event, 'conversations', (j) => j['id'] == conversationId) ||
                rows(event, 'bots', (j) => directIds.contains(j['id']));
      } else {
        final ownerIds = sorted.values.toSet();
        relevant = rows(
                event,
                'accounts',
                (j) =>
                    _communityContains(j['id'] as String) &&
                    ownerIds.contains(j['id'])) ||
            rows(
                event,
                'bots',
                (j) =>
                    j['draft'] != true &&
                    _communityContains(j['ownerId'] as String) &&
                    (feedVisibility == 'public' ||
                        sorted.containsKey(j['id']) ||
                        (feedVisibility == 'private' &&
                            j['id'] == feedAuthorId))) ||
            (feedVisibility == 'friends' &&
                rows(
                    event,
                    'friends',
                    (j) =>
                        j['a'] == feedAuthorId ||
                        j['b'] == feedAuthorId ||
                        j['a'] == feedAuthorOwner ||
                        j['b'] == feedAuthorOwner));
      }
      if (relevant) revisions.add(event.id);
    }
    return KeyAudience._(conversationId, sorted, revisions);
  }

  IdentityPublic _trusted(String accountId) {
    _keyRequire(
        _communityContains(accountId), 'forbidden', '账户未处于当前可信历史名册revision');
    return trustedAccounts[accountId] ??
        _keyFail('forbidden', '账户公钥未钉住，不能信任信封自报身份');
  }

  void _identity(Identity identity) {
    final pinned = _trusted(identity.public.accountId);
    _keyRequire(
        canonicalJson(pinned.toJson()) ==
            canonicalJson(identity.public.toJson()),
        'forbidden',
        '当前身份的公钥与已钉住目录不符');
  }

  void _distributor(String senderId, KeyAudience audience) {
    _trusted(senderId);
    _keyRequire(audience.accountIds.contains(senderId), 'forbidden',
        '只有当期可读成员或闺房合法旁观 owner 可分发该范围密钥');
  }

  Future<String> _commitment(ConversationKey key) => objectHash({
        'domain': 'zaizuo.conversation.key_commitment.v1',
        'community': communityId,
        'conversation': key.conversationId,
        'epoch': key.epoch,
        'key': base64Encode(key.bytes)
      });

  Future<String> _fingerprint(ConversationKey key) => objectHash({
        'domain': 'zaizuo.key_epoch_freshness.v1',
        'community': communityId,
        'conversation': key.conversationId,
        'key': base64Encode(key.bytes)
      });

  Future<void> _signedAnnouncement(KeyEpochAnnouncement announcement,
      {bool historicalCheckpoint = false}) async {
    final body = announcement.body;
    _keyFields(body, {
      'version',
      'type',
      'community',
      'conversation',
      'epoch',
      'issuer',
      'principals',
      'authorization_events',
      'audience_hash',
      'policy_hash',
      'key_commitment',
      'key_fingerprint'
    });
    _keyRequire(body['version'] == 1 && body['type'] == 'zaizuo.key_epoch.v1',
        'bad_request', '未知密钥公告版本/类型');
    _keyRequire(
        _keyString(body, 'community') == communityId, 'forbidden', '密钥公告社区不匹配');
    _keyString(body, 'conversation', max: 256);
    _keyEpoch(body);
    final issuer = _keyString(body, 'issuer');
    final owners = _keyObject(body['principals']);
    for (final entry in owners.entries) {
      _keyRequire(
          entry.key.isNotEmpty &&
              entry.value is String &&
              (entry.value as String).isNotEmpty,
          'bad_request',
          '无效接收主体/owner映射');
    }
    final events = body['authorization_events'];
    _keyRequire(
        events is List &&
            events.every((id) => id is String && id.isNotEmpty) &&
            events.toSet().length == events.length,
        'bad_request',
        '无效授权修订列表');
    for (final field in [
      'audience_hash',
      'policy_hash',
      'key_commitment',
      'key_fingerprint'
    ]) {
      _keyRequire(RegExp(r'^[a-f0-9]{64}$').hasMatch(_keyString(body, field)),
          'bad_request', '无效密钥承诺/策略摘要');
    }
    _keyRequire(
        await verifySignature(
            body,
            announcement.signature,
            (historicalCheckpoint
                    ? (trustedAccounts[issuer] ??
                        _keyFail('forbidden', '历史公告账户公钥未钉住'))
                    : _trusted(issuer))
                .signingKey),
        'forbidden',
        '密钥公告签名无效');
    _keyRequire(
        body['audience_hash'] == await objectHash(owners) &&
            body['policy_hash'] ==
                await objectHash(
                    {'principals': owners, 'authorization_events': events}),
        'bad_request',
        '密钥公告授权摘要不匹配');
  }

  void _knownEpoch(KeyEpochAnnouncement announcement) {
    _notConflicted(announcement.conversationId);
    final known = _epochs[announcement.conversationId]?[announcement.epoch];
    if (known != null &&
        (known.keyCommitment != announcement.keyCommitment ||
            known.body['policy_hash'] != announcement.body['policy_hash'])) {
      _conflicts.add(announcement.conversationId);
      _keyFail('epoch_conflict', '同一会话epoch已有不同密钥或授权公告，已锁止会话并等待可信裁决');
    }
    final reused = (_epochs[announcement.conversationId]?.values ??
            const <KeyEpochAnnouncement>[])
        .any((old) =>
            old.epoch != announcement.epoch &&
            old.body['key_fingerprint'] ==
                announcement.body['key_fingerprint']);
    _keyRequire(!reused, 'invalid_key', '新epoch不得复用任何已知旧epoch密钥');
    final current = currentAnnouncement(announcement.conversationId);
    _keyRequire(current == null || announcement.epoch >= current.epoch,
        'stale_key', '拒绝回退到旧epoch');
  }

  void _currentPolicy(KeyEpochAnnouncement announcement) {
    final audience = resolveAuthorizedRecipients(announcement.conversationId);
    _distributor(announcement.issuerAccountId, audience);
    _keyRequire(
        canonicalJson(announcement.body['principals']) ==
                canonicalJson(audience.principalOwnerIds) &&
            canonicalJson(announcement.body['authorization_events']) ==
                canonicalJson(audience.authorizationEventIds),
        'stale_key',
        '成员/房间授权已变更，必须生成独立随机新epoch，不能给新人旧钥匙');
    _knownEpoch(announcement);
  }

  void _record(KeyEpochAnnouncement announcement) {
    _epochs
        .putIfAbsent(announcement.conversationId, () => {})
        .putIfAbsent(announcement.epoch, () => announcement);
  }

  /// 公告已携带合法成员签名，接收者无需先有此epoch或等社区owner在线。
  Future<void> authorizeAnnouncement(
      {required KeyEpochAnnouncement announcement}) async {
    await _signedAnnouncement(announcement);
    _currentPolicy(announcement);
    _record(announcement);
  }

  /// 内容发送/按序重放之前调用，防止成员变化后继续用旧key加密未来内容。
  /// 旧历史解密不调用此接口；必须在原始事件当时的授权状态重放验证。
  Future<void> validateCurrentKey({required ConversationKey key}) async {
    _notConflicted(key.conversationId);
    final announcement = currentAnnouncement(key.conversationId);
    _keyRequire(announcement != null, 'not_found', '尚未收到该会话的合法epoch公告');
    _currentPolicy(announcement!);
    _keyRequire(
        key.epoch == announcement.epoch, 'stale_key', '内容使用的epoch不是当前已授权期次');
    _keyRequire(
        await _commitment(key) == announcement.keyCommitment &&
            await _fingerprint(key) == announcement.body['key_fingerprint'],
        'invalid_key',
        '内容key与当期公告承诺不匹配');
    _currentPolicy(announcement);
  }

  /// 每个epoch独立随机32字节，绝不从旧key派生/只用旧key封装新key。
  Future<KeyRotation> generate(
      {required Identity sender, required String conversationId}) async {
    _identity(sender);
    _notConflicted(conversationId);
    final audience = resolveAuthorizedRecipients(conversationId);
    _distributor(sender.public.accountId, audience);
    final epoch = (currentAnnouncement(conversationId)?.epoch ?? 0) + 1;
    _keyRequire(epoch <= 9007199254740991, 'bad_request', 'epoch已溢出');
    final key = ConversationKey.generate(conversationId, epoch);
    final body = <String, dynamic>{
      'version': 1,
      'type': 'zaizuo.key_epoch.v1',
      'community': communityId,
      'conversation': conversationId,
      'epoch': epoch,
      'issuer': sender.public.accountId,
      'principals': audience.principalOwnerIds,
      'authorization_events': audience.authorizationEventIds,
      'audience_hash': await objectHash(audience.principalOwnerIds),
      'policy_hash': await objectHash({
        'principals': audience.principalOwnerIds,
        'authorization_events': audience.authorizationEventIds
      }),
      'key_commitment': await _commitment(key),
      'key_fingerprint': await _fingerprint(key)
    };
    final announcement = KeyEpochAnnouncement._(body, await sender.sign(body));
    await authorizeAnnouncement(announcement: announcement);
    return KeyRotation._(key, announcement);
  }

  Future<KeyGrant> issue(
      {required Identity sender,
      required ConversationKey key,
      required KeyEpochAnnouncement announcement,
      required String recipientPrincipalId}) async {
    _identity(sender);
    await _signedAnnouncement(announcement);
    _currentPolicy(announcement);
    final audience = resolveAuthorizedRecipients(key.conversationId);
    _distributor(sender.public.accountId, audience);
    final account = audience.principalOwnerIds[recipientPrincipalId];
    _keyRequire(
        account != null, 'forbidden', '目标不是当前获准接收主体，不向未加入/已退/被ban主体分发新epoch');
    _keyRequire(
        key.conversationId == announcement.conversationId &&
            key.epoch == announcement.epoch &&
            await _commitment(key) == announcement.keyCommitment &&
            await _fingerprint(key) == announcement.body['key_fingerprint'],
        'invalid_key',
        '密钥不匹配已签公告');
    final wrapped = await key.wrapFor(_trusted(account!),
        sender: sender, communityId: communityId);
    final body = <String, dynamic>{
      'version': 1,
      'type': 'zaizuo.key_grant.v1',
      'community': communityId,
      'conversation': key.conversationId,
      'epoch': key.epoch,
      'sender': sender.public.accountId,
      'recipient_principal': recipientPrincipalId,
      'recipient_account': account,
      'announcement': announcement.toJson(),
      'envelope': wrapped
    };
    final grant = KeyGrant._(body, await sender.sign(body));
    // 异步签名/封装期间可能发生退群/ban；返回前按当前授权再检查。
    _currentPolicy(announcement);
    _distributor(sender.public.accountId,
        resolveAuthorizedRecipients(key.conversationId));
    _record(announcement);
    return grant;
  }

  Future<ConversationKey> receive(
      {required Identity recipient, required KeyGrant grant}) async {
    _identity(recipient);
    final body = grant.body;
    _keyFields(body, {
      'version',
      'type',
      'community',
      'conversation',
      'epoch',
      'sender',
      'recipient_principal',
      'recipient_account',
      'announcement',
      'envelope'
    });
    _keyRequire(body['version'] == 1 && body['type'] == 'zaizuo.key_grant.v1',
        'bad_request', '未知密钥grant版本/类型');
    _keyRequire(_keyString(body, 'community') == communityId, 'forbidden',
        '密钥grant社区不匹配');
    final conversation = _keyString(body, 'conversation', max: 256);
    final epoch = _keyEpoch(body);
    final sender = _keyString(body, 'sender');
    final principal = _keyString(body, 'recipient_principal');
    final account = _keyString(body, 'recipient_account');
    _keyRequire(
        account == recipient.public.accountId, 'forbidden', '密钥grant不是给当前接收账户');
    final pinned = _trusted(sender);
    _keyRequire(await verifySignature(body, grant.signature, pinned.signingKey),
        'forbidden', '密钥grant签名无效');
    final announcement = grant.announcement;
    await _signedAnnouncement(announcement);
    _keyRequire(
        announcement.conversationId == conversation &&
            announcement.epoch == epoch,
        'invalid_key',
        'grant和公告scope/epoch不匹配');
    _currentPolicy(announcement);
    final audience = resolveAuthorizedRecipients(conversation);
    _distributor(sender, audience);
    _keyRequire(audience.principalOwnerIds[principal] == account, 'forbidden',
        '接收principal与当前授权owner不匹配');
    final envelope = _keyObject(body['envelope']);
    ConversationKey key;
    try {
      key = await ConversationKey.unwrap(envelope, recipient,
          authorizedSender: pinned, communityId: communityId);
    } catch (_) {
      _keyFail('invalid_key', 'recipient封装签名/解密失败');
    }
    _keyRequire(
        key.conversationId == conversation &&
            key.epoch == epoch &&
            await _commitment(key) == announcement.keyCommitment &&
            await _fingerprint(key) == announcement.body['key_fingerprint'],
        'invalid_key',
        '解密的key与公告承诺不符');
    _currentPolicy(announcement);
    _distributor(sender, resolveAuthorizedRecipients(conversation));
    _record(announcement);
    return key;
  }

  /// 只保存公开公告和最高epoch/冲突钉住记录，不保存key、Identity或私钥。
  Map<String, dynamic> toJson() => {
        'version': 1,
        'community': communityId,
        'conflicts': _conflicts.toList()..sort(),
        'announcements': _epochs.values
            .expand((epochs) => epochs.values)
            .map((a) => a.toJson())
            .toList()
      };

  /// 可信本机metadata快照恢复：验公告签名和摘要，但不声称重新证明历史成员资格。
  /// 新issue/receive仍须匹配当前策略；不能把远端任意JSON当作可信检查点。
  static Future<ConversationKeyManager> fromJson(Map<String, dynamic> json,
      {required ChatService service,
      required String communityId,
      required Map<String, IdentityPublic> trustedAccounts,
      Set<String>? communityAccountIds}) async {
    _keyFields(json, {'version', 'community', 'announcements', 'conflicts'});
    _keyRequire(
        json['version'] == 1 &&
            json['community'] == communityId &&
            json['announcements'] is List,
        'bad_request',
        '无效key manager快照');
    final manager = ConversationKeyManager(
        service: service,
        communityId: communityId,
        trustedAccounts: trustedAccounts,
        communityAccountIds: communityAccountIds);
    final records = (json['announcements'] as List)
        .map((j) => KeyEpochAnnouncement.fromJson(_keyObject(j)))
        .toList()
      ..sort((a, b) => a.epoch.compareTo(b.epoch));
    for (final announcement in records) {
      await manager._signedAnnouncement(announcement,
          historicalCheckpoint: true);
      manager._knownEpoch(announcement);
      manager._record(announcement);
    }
    final conflicts = json['conflicts'];
    _keyRequire(
        conflicts is List &&
            conflicts.every((id) => id is String && id.isNotEmpty),
        'bad_request',
        '无效冲突锁止记录');
    manager._conflicts.addAll((conflicts as List).cast<String>());
    return manager;
  }
}
