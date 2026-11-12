import 'dart:async';

import 'package:zaizuo_core/zaizuo_core.dart';
import 'package:zaizuo_domain/zaizuo_domain.dart';

import 'commands.dart';
import 'key_manager.dart';

/// 把加密日志投影为业务状态。种子是本机验证过的社区检查点，不接受远端任意patch。
/// 本原型每次重放所有可解密命令；大社区需增量检查点与冲突语义，见README。
class EncryptedReplica {
  final FileEventStore store;
  final DeviceCredentials device;
  final Identity? identity;
  final Map<String, dynamic> _seed;
  final Map<String, ConversationKey> _keys = {};
  final Map<String, String> rejected = {};
  final StreamController<MessageRecord> _messages =
      StreamController.broadcast();
  late ChatService _service;
  Future<void> _tail = Future.value();
  bool _closed = false;
  bool _writeFailed = false;
  Future<void>? _closing;
  void _requireWritable() {
    if (_closed || _writeFailed) throw StateError('当前副本已关闭或写入失败，须检查日志后重新打开');
  }

  EncryptedReplica._(this.store, this.device, this._seed, this.identity);
  ConversationKeyManager? _keyManager;
  int _manifestRevision = 1;
  final Map<int, Set<String>> _manifestAccounts = {};
  int get manifestRevision => _manifestRevision;
  List<ConversationKey> get keys => List.unmodifiable(_keys.values);
  ChatService get service => _service;
  Stream<MessageRecord> get messages => _messages.stream;

  static Future<EncryptedReplica> open(
      {required FileEventStore store,
      required DeviceCredentials device,
      required ChatState seed,
      Identity? identity,
      int manifestRevision = 1,
      Map<int, Set<String>>? manifestAccounts,
      required Iterable<ConversationKey> keys}) async {
    if (device.certificate == null ||
        device.certificate!.communityId != store.trust.communityId)
      throw StateError('设备授权与本地社区不匹配');
    if (identity != null &&
        identity.public.accountId != device.certificate!.accountId)
      throw StateError('当前身份与设备证书不匹配');
    final replica = EncryptedReplica._(store, device, seed.toJson(), identity);
    replica._manifestRevision = manifestRevision;
    replica._manifestAccounts.addAll(
        (manifestAccounts ?? {manifestRevision: seed.accounts.keys.toSet()})
            .map((k, v) => MapEntry(k, Set.unmodifiable(v))));
    for (final key in keys) replica.addKey(key);
    replica._service = ChatService(ChatState.fromJson(replica._seed));
    await replica.refresh();
    return replica;
  }

  void addKey(ConversationKey key) {
    final name = '${key.conversationId}:${key.epoch}';
    final previous = _keys[name];
    if (previous != null && !equalBytes(previous.bytes, key.bytes))
      throw StateError('同会话期次已有不同密钥，拒绝静默替换');
    _keys[name] = key;
  }

  ConversationKey _key(String conversation, int epoch) =>
      _keys['$conversation:$epoch'] ?? (throw StateError('没有此会话密钥'));
  ConversationKey _latest(String conversation) {
    final keys = _keys.values
        .where((k) => k.conversationId == conversation)
        .toList()
      ..sort((a, b) => b.epoch.compareTo(a.epoch));
    if (keys.isEmpty) throw StateError('没有此会话密钥');
    return keys.first;
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    if (_closed) return Future.error(StateError('副本已关闭'));
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await action());
      } catch (e, st) {
        result.completeError(e, st);
      }
    });
    return result.future;
  }

  void _verifyActor(String actorId, String signer, ChatService service) {
    final actor = service.actor(actorId);
    if (actor.ownerId != signer)
      throw DomainException('forbidden', '签名账号不能代他人的主体发言');
  }

  /// 内容命令必须用实际目标会话密钥；社区配置通道不允许承载聊天明文。
  void _verifyRoute(String conversation, String actorId, String op,
      Map<String, dynamic> params, ChatService service) {
    if (op == 'bot.draft')
      throw DomainException('forbidden', '机器人草案只保存在本机，不允许进入共享事件日志');
    String expected;
    switch (op) {
      case 'message.send':
        expected = params['conversation'] as String;
        break;
      case 'forum.post':
        expected = params['room'] as String;
        break;
      case 'forum.reply':
        final post = service.state.forumPosts[params['post']];
        if (post == null) throw DomainException('not_found', '帖子尚不可见');
        expected = post.roomId;
        break;
      case 'feed.post':
        final visibility = params['visibility'] as String? ?? 'friends';
        expected = 'feed:$actorId:$visibility';
        break;
      case 'feed.comment':
      case 'feed.like':
        final post = service.state.feedPosts[params['post']];
        if (post == null) throw DomainException('not_found', '朋友圈帖子尚不可见');
        expected = 'feed:${post.authorId}:${post.visibility}';
        break;
      default:
        expected = 'control:${store.trust.communityId}';
    }
    if (conversation != expected)
      throw DomainException('forbidden', '事件加密通道与目标范围不匹配');
    if ({
          'message.send',
          'forum.post',
          'forum.reply',
          'feed.post',
          'feed.comment',
          'feed.like'
        }.contains(op) &&
        (conversation.startsWith('control:') ||
            (!op.startsWith('feed.') && conversation.startsWith('feed:'))))
      throw DomainException('forbidden', '内容不能复用保留的控制/朋友圈命名空间');
  }

  String routeFor(
      String actorId, String operation, Map<String, dynamic> params) {
    switch (operation) {
      case 'message.send':
        return readString(params, 'conversation');
      case 'forum.post':
        return readString(params, 'room');
      case 'forum.reply':
        final post = _service.state.forumPosts[params['post']];
        if (post == null) throw DomainException('not_found', '帖子尚不可见');
        return post.roomId;
      case 'feed.post':
        return 'feed:$actorId:${params['visibility'] as String? ?? 'friends'}';
      case 'feed.comment':
      case 'feed.like':
        final post = _service.state.feedPosts[params['post']];
        if (post == null) throw DomainException('not_found', '朋友圈帖子尚不可见');
        return 'feed:${post.authorId}:${post.visibility}';
      default:
        return 'control:${store.trust.communityId}';
    }
  }

  Future<void> replaceSeed(ChatState seed,
          {int? manifestRevision, Map<int, Set<String>>? manifestAccounts}) =>
      _serial(() async {
        _seed
          ..clear()
          ..addAll(seed.toJson());
        if (manifestRevision != null) {
          if (manifestRevision < _manifestRevision)
            throw StateError('不能回退名册修订');
          _manifestRevision = manifestRevision;
        }
        if (manifestAccounts != null) {
          for (final entry in manifestAccounts.entries) {
            final prior = _manifestAccounts[entry.key];
            if (prior != null &&
                (prior.length != entry.value.length ||
                    !prior.containsAll(entry.value)))
              throw StateError('已知历史名册内容不可改写');
            _manifestAccounts[entry.key] = Set.unmodifiable(entry.value);
          }
        }
        if (!_manifestAccounts.containsKey(_manifestRevision))
          _manifestAccounts[_manifestRevision] =
              Set.unmodifiable(seed.accounts.keys);
        await _refresh();
      });

  ChatService _commandService(ChatState state, String eventId, int createdAt) {
    var counter = 0;
    return ChatService(state,
        now: () => DateTime.fromMillisecondsSinceEpoch(createdAt, isUtc: true),
        idGenerator: (prefix) => '$prefix:$eventId:${counter++}');
  }

  Future<void> refresh() => _serial(() async {
        final prior = _service.state.messages.keys.toSet();
        await _refresh();
        for (final message in _service.state.messages.values
            .where((m) => !prior.contains(m.id))) {
          _messages.add(message);
        }
      });
  Future<void> _refresh({bool retryForLearnedKeys = true}) async {
    final priorKeyCount = _keys.length;
    final state = ChatState.fromJson(_seed);
    final keyService = ChatService(state);
    final keyManager = ConversationKeyManager(
        service: keyService,
        communityId: store.trust.communityId,
        trustedAccounts: store.trust.accounts);
    rejected.clear();
    final deviceRevisions = <String, int>{};
    for (final event in store.index.sorted()) {
      if (!_keys.containsKey('${event.conversation}:${event.epoch}')) continue;
      try {
        final body = await event.decrypt(_key(event.conversation, event.epoch));
        if (body['version'] != 1) throw const FormatException('未知命令版本');
        final actorId = readString(body, 'actor');
        final op = readString(body, 'operation');
        final params = body['params'] as Map<String, dynamic>;
        final revision = body.containsKey('manifest_revision')
            ? readInt(body, 'manifest_revision', min: 1)
            : 1;
        if (revision < (deviceRevisions[event.origin] ?? 1))
          throw StateError('同设备已确认新名册后不能回退旧修订发消息');
        deviceRevisions[event.origin] = revision;
        final context = _manifestAccounts[revision];
        if (context == null || !context.contains(event.author))
          throw StateError('未知名册修订或签名者当时尚未入驻');
        keyManager.setCommunityAccounts(context);
        if (op == 'key.rotate' || op == 'key.grant') {
          if (event.conversation != 'control:${store.trust.communityId}' ||
              actorId != event.author) throw StateError('密钥协议通道或签名主体错误');
          if (op == 'key.rotate') {
            final announcement = KeyEpochAnnouncement.fromJson(
                params['announcement'] as Map<String, dynamic>);
            if (announcement.issuerAccountId != event.author)
              throw StateError('密钥公告签名者与设备作者不同');
            await keyManager.authorizeAnnouncement(announcement: announcement);
          } else {
            final grant =
                KeyGrant.fromJson(params['grant'] as Map<String, dynamic>);
            if (grant.body['sender'] != event.author)
              throw StateError('密钥分发签名者与设备作者不同');
            if (identity != null &&
                grant.body['recipient_account'] == identity!.public.accountId) {
              addKey(
                  await keyManager.receive(recipient: identity!, grant: grant));
            }
          }
          continue;
        }
        final commandService =
            _commandService(state, event.id, event.header['created_at'] as int);
        try {
          _verifyActor(actorId, event.author, commandService);
          _verifyRoute(event.conversation, actorId, op, params, commandService);
          if (event.conversation != 'control:${store.trust.communityId}') {
            await keyManager.validateCurrentKey(
                key: _key(event.conversation, event.epoch));
          }
          applyCommand(commandService, actorId, op, params);
        } finally {
          await commandService.close();
        }
      } catch (error) {
        rejected[event.id] =
            error is DomainException ? error.code : 'invalid_command';
      }
    }
    keyManager.setCommunityAccounts(_manifestAccounts[_manifestRevision]!);
    final old = _service;
    _service = ChatService(state);
    _keyManager = await ConversationKeyManager.fromJson(keyManager.toJson(),
        service: _service,
        communityId: store.trust.communityId,
        trustedAccounts: store.trust.accounts,
        communityAccountIds: _manifestAccounts[_manifestRevision]);
    await keyService.close();
    await old.close();
    if (retryForLearnedKeys && _keys.length > priorKeyCount)
      await _refresh(retryForLearnedKeys: false);
  }

  /// 任意当前合法成员发布新期次与逐接收者封装，正文key不进入控制事件明文。
  Future<void> rotateAndShare(String conversationId) =>
      _serial(() => _rotateAndShare(conversationId));
  Future<void> _rotateAndShare(String conversationId) async {
    _requireWritable();
    final currentIdentity = identity;
    if (currentIdentity == null) throw StateError('此客户端没有可签发密钥的身份');
    // 规划阶段使用副本，尚未落盘时不推进活动manager的期次。
    final manager = await ConversationKeyManager.fromJson(_keyManager!.toJson(),
        service: _service,
        communityId: store.trust.communityId,
        trustedAccounts: store.trust.accounts,
        communityAccountIds: _manifestAccounts[_manifestRevision]);
    final rotation = await manager.generate(
        sender: currentIdentity, conversationId: conversationId);
    final grants = <KeyGrant>[];
    for (final principal in manager
        .resolveAuthorizedRecipients(conversationId)
        .principalOwnerIds
        .keys) {
      grants.add(await manager.issue(
          sender: currentIdentity,
          key: rotation.key,
          announcement: rotation.announcement,
          recipientPrincipalId: principal));
    }
    final control = _latest('control:${store.trust.communityId}');
    try {
      await store.append(device: device, key: control, body: {
        'version': 1,
        'actor': currentIdentity.public.accountId,
        'manifest_revision': _manifestRevision,
        'operation': 'key.rotate',
        'params': {'announcement': rotation.announcement.toJson()}
      });
      for (final grant in grants) {
        await store.append(device: device, key: control, body: {
          'version': 1,
          'actor': currentIdentity.public.accountId,
          'manifest_revision': _manifestRevision,
          'operation': 'key.grant',
          'params': {'grant': grant.toJson()}
        });
      }
      addKey(rotation.key);
      await _refresh();
    } catch (_) {
      _writeFailed = true;
      rethrow;
    }
  }

  /// 新成员不向社区root请求审批；任意在线持钥成员发现授权变化后可调用。
  Future<void> ensureConversationKey(String conversationId) =>
      _serial(() async {
        _requireWritable();
        if (identity == null) {
          await _keyManager!.validateCurrentKey(key: _latest(conversationId));
          return;
        }
        final manager = _keyManager!;
        final announcement = manager.currentAnnouncement(conversationId);
        final audience = manager.resolveAuthorizedRecipients(conversationId);
        if (announcement == null ||
            canonicalJson(announcement.body['authorization_events']) !=
                canonicalJson(audience.authorizationEventIds) ||
            !_keys.containsKey('$conversationId:${announcement.epoch}')) {
          await _rotateAndShare(conversationId);
        }
      });

  /// 校验候选状态 -> 加密写盘flush -> 重放确认。成功返回只代表本地持久化。
  Future<Map<String, dynamic>> execute(
      {required String actorId,
      required String operation,
      required Map<String, dynamic> params,
      required String conversation,
      DateTime? now}) {
    _requireWritable();
    return _executeReady(
        actorId: actorId,
        operation: operation,
        params: immutableProtocolObject(params),
        conversation: conversation,
        now: now);
  }

  Future<Map<String, dynamic>> _executeReady(
      {required String actorId,
      required String operation,
      required Map<String, dynamic> params,
      required String conversation,
      DateTime? now}) async {
    _verifyActor(actorId, device.certificate!.accountId, _service);
    _verifyRoute(conversation, actorId, operation, params, _service);
    // 先执行候选业务校验，再允许产生密钥公告，避免未授权动作产生副作用。
    final preflight = _commandService(
        ChatState.fromJson(_service.state.toJson()),
        randomId(),
        (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch);
    try {
      applyCommand(preflight, actorId, operation, params);
    } finally {
      await preflight.close();
    }
    if (conversation != 'control:${store.trust.communityId}')
      await ensureConversationKey(conversation);
    return _serial(() async {
      _requireWritable();
      final certificate = device.certificate!;
      _verifyActor(actorId, certificate.accountId, _service);
      _verifyRoute(conversation, actorId, operation, params, _service);
      if (conversation != 'control:${store.trust.communityId}')
        await _keyManager!.validateCurrentKey(key: _latest(conversation));
      final id = randomId();
      final at = (now ?? DateTime.now()).toUtc();
      final candidate = ChatState.fromJson(_service.state.toJson());
      final verifier =
          _commandService(candidate, id, at.millisecondsSinceEpoch);
      Object? result;
      try {
        result = applyCommand(verifier, actorId, operation, params);
      } finally {
        await verifier.close();
      }
      final prior = _service.state.messages.keys.toSet();
      final event = await store.append(
          device: device,
          key: _latest(conversation),
          eventId: id,
          now: at,
          body: {
            'version': 1,
            'actor': actorId,
            'manifest_revision': _manifestRevision,
            'operation': operation,
            'params': params
          });
      await _refresh();
      if (rejected.containsKey(event.id))
        throw StateError('本地命令重放失败: ${rejected[event.id]}');
      for (final message in _service.state.messages.values
          .where((m) => !prior.contains(m.id))) _messages.add(message);
      return {'event_id': event.id, 'result': _result(result)};
    });
  }

  Object? _result(Object? result) {
    if (result == null) return null;
    // 业务记录均提供toJson；这里不接收外来动态对象。
    return switch (result) {
      MessageRecord r => r.toJson(),
      BotRecord r => r.toJson(),
      SpaceRecord r => r.toJson(),
      MembershipRecord r => r.toJson(),
      ConversationRecord r => r.toJson(),
      ForumPostRecord r => r.toJson(),
      FeedPostRecord r => r.toJson(),
      FeedCommentRecord r => r.toJson(),
      RoomRecord r => r.toJson(),
      _ => throw StateError('未知命令返回类型'),
    };
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    return _closing = () async {
      await _tail;
      await _service.close();
      await _messages.close();
    }();
  }
}
