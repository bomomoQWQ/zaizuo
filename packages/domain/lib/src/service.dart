part of '../zaizuo_domain.dart';

/// 唯一业务写入口。Actor 句柄不是网络凭据；调用者须先在可信适配器认证。
/// 所有写操作同步检查并以单个不可变事件提交，不在 await 间隙部分写入。
final class ChatService {
  final ChatState state;
  final DateTime Function() _now;
  final String Function(String prefix)? _idGenerator;
  final String _instanceId = _randomInstanceId();
  final Set<String> _issuedIds = {};
  final Object _actorToken = Object();
  final StreamController<MessageRecord> _messageController =
      StreamController<MessageRecord>.broadcast();
  bool _closed = false;
  ChatService(this.state,
      {DateTime Function()? now, String Function(String prefix)? idGenerator})
      : _now = now ?? DateTime.now,
        _idGenerator = idGenerator;

  static String _randomInstanceId() {
    final random = Random.secure();
    return List.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// 原始提交广播；适配器必须为每个已绑定主体重新按读权限过滤。
  /// 不重播、无已读/在线副作用，不替代持久化或可靠消息同步。
  Stream<MessageRecord> get messageEvents => _messageController.stream;
  Future<void> close() async {
    _closed = true;
    await _messageController.close();
  }

  int get _time => _now().toUtc().millisecondsSinceEpoch;
  String _next(String prefix) {
    bool used(String id) =>
        _issuedIds.contains(id) ||
        state._principalExists(id) ||
        state._spaces.containsKey(id) ||
        state._rooms.containsKey(id) ||
        state._conversations.containsKey(id) ||
        state._messages.containsKey(id) ||
        state._forumPosts.containsKey(id) ||
        state._feedPosts.containsKey(id) ||
        state._feedComments.containsKey(id) ||
        state._events.any((e) => e.id == id);
    if (_idGenerator != null) {
      final id = _id(_idGenerator(prefix), 'generated id');
      _require(!used(id), 'conflict', 'idGenerator 返回了重复编号');
      _issuedIds.add(id);
      return id;
    }
    var number = state._events.length + 1;
    while (used('$prefix:$_instanceId:$number')) {
      number++;
    }
    final id = '$prefix:$_instanceId:$number';
    _issuedIds.add(id);
    return id;
  }

  String get _communityOwner =>
      state.communityOwnerId ??
      (state._accounts.isNotEmpty ? state._accounts.values.first.id : '');

  Actor actor(String principalId) {
    final p = _principal(principalId);
    _require(p.active && !p.draft, 'forbidden', '主体未入驻或已退驻');
    return Actor._(p.id, p.ownerId, p.isBot, _actorToken);
  }

  PrincipalRecord _principal(String id) {
    final account = state._accounts[id];
    if (account != null)
      return PrincipalRecord(
          id: id, ownerId: id, isBot: false, displayName: account.displayName);
    final bot = state._bots[id];
    if (bot != null) return bot.principal;
    _fail('not_found', '主体不存在');
  }

  PrincipalRecord _auth(Actor actor) {
    // 每个同步公开调用重新保留临时编号；失败命令不得留下业务状态或编号占位。
    _issuedIds.clear();
    _require(!_closed, 'bad_request', '服务已关闭');
    _require(identical(actor._serviceToken, _actorToken), 'forbidden',
        'Actor 必须由当前服务的可信身份解析入口产生');
    final p = _principal(actor.id);
    _require(
        p.ownerId == actor.ownerId &&
            p.isBot == actor.isBot &&
            p.active &&
            !p.draft,
        'forbidden',
        '主体身份或入驻状态无效');
    return p;
  }

  void _owner(Actor actor) {
    _auth(actor);
    _require(!actor.isBot && actor.id == actor.ownerId, 'forbidden',
        '该社交/管理操作仅允许主账户，机器人不可继承 owner 权限');
  }

  void _ownsBot(Actor actor, BotRecord bot) {
    _owner(actor);
    _require(bot.ownerId == actor.id, 'forbidden', '只能管理自己的机器人');
  }

  void _cap(Actor actor, String cap) {
    if (actor.isBot)
      _require(state._bots[actor.id]!.caps.contains(cap), 'forbidden',
          '机器人未获 $cap 内容能力');
  }

  void _quota(int current, int limit, String label) {
    _require(
        limit == 0 || current < limit, 'quota_exceeded', '$label 已达上限 $limit');
  }

  void _newPrincipal(String id) {
    _id(id);
    _require(!state._principalExists(id), 'conflict', '主体编号已存在');
  }

  SpaceRecord _space(String id) =>
      state._spaces[id] ?? _fail('not_found', '空间不存在');
  RoomRecord _room(String id) =>
      state._rooms[id] ?? _fail('not_found', '房间不存在');
  ConversationRecord _conversation(String id) =>
      state._conversations[id] ?? _fail('not_found', '会话不存在');
  BotRecord _bot(String id) => state._bots[id] ?? _fail('not_found', '机器人不存在');

  JsonMap? _retry(Actor actor, String operation, String? key, JsonMap payload) {
    if (key == null) return null;
    _id(key, 'idempotencyKey');
    final item = state._idempotency[_scopeKey(actor.id, key)];
    if (item == null) return null;
    _require(
        item['operation'] == operation &&
            item['fingerprint'] == _canonical(payload),
        'idempotency_conflict',
        '相同幂等键已用于不同请求');
    return _jsonMap(item['result']);
  }

  void _commit(String operation, String actorId, JsonMap data,
      {int? atMs, String? idempotencyKey, JsonMap? payload, JsonMap? result}) {
    _require(!_closed, 'bad_request', '服务已关闭');
    final patch = <String, dynamic>{...data};
    if (idempotencyKey != null) {
      patch['idempotency'] = {
        'scope': _scopeKey(actorId, idempotencyKey),
        'operation': operation,
        'fingerprint': _canonical(payload),
        'result': result ?? <String, dynamic>{}
      };
    }
    for (final collection in [
      'accounts',
      'bots',
      'spaces',
      'rooms',
      'conversations',
      'messages',
      'forumPosts',
      'feedPosts',
      'feedComments'
    ]) {
      for (final raw in data[collection] as List? ?? const []) {
        final id = _jsonMap(raw)['id'];
        if (id is String) _issuedIds.add(id);
      }
    }
    final event = DomainEvent(
        id: _next('event'),
        type: operation,
        actorId: actorId,
        createdAtMs: atMs ?? _time,
        data: patch);
    state._apply(event);
    for (final raw in data['messages'] as List? ?? const []) {
      _messageController.add(state._messages[_jsonMap(raw)['id']]!);
    }
  }

  JsonMap _use(String key, int at) => {'key': key, 'atMs': at};
  int _usageCount(String key, int at) => (state._usage[key] ?? const <int>[])
      .where((t) => t > at - const Duration(hours: 1).inMilliseconds)
      .length;
  void _hourly(String key, int limit, int at) {
    _require(limit == 0 || _usageCount(key, at) < limit, 'rate_limited',
        '每小时次数已达上限 $limit');
  }

  void _slow(String key, int interval, int at) {
    final values = state._usage[key];
    if (interval == 0 || values == null || values.isEmpty) return;
    final latest = values.reduce((a, b) => a > b ? a : b);
    _require(at - latest >= interval, 'rate_limited', '慢速模式间隔尚未结束');
  }

  void _content(List<JsonMap> parts) {
    _require(parts.isNotEmpty, 'bad_request', '消息内容不得为空');
    _parts(parts);
    for (final p in parts) {
      _require(p['type'] is String && (p['type'] as String).isNotEmpty,
          'bad_request', '每个消息段需要 type');
    }
  }

  AccountRecord registerAccount(
      {required String id, required String name, required String displayName}) {
    _issuedIds.clear();
    _newPrincipal(id);
    _id(name, 'name');
    _displayName(displayName);
    final normalized = name.trim().toLowerCase();
    _require(RegExp(r'^[a-z0-9_]{1,14}$').hasMatch(normalized), 'bad_request',
        '账户名只能是 1–14 位小写英文字母、数字、下划线');
    _require(
        !state._names.containsKey(normalized), 'conflict', '账户名已存在（大小写不敏感）');
    _quota(state._accounts.length, state.config.maxAccounts, '社区账户');
    if (state._accounts.isEmpty && state.communityOwnerId != null)
      _require(id == state.communityOwnerId, 'forbidden', '首个账户必须是配置的社区 owner');
    final account = AccountRecord(
        id: id, name: normalized, displayName: displayName, createdAtMs: _time);
    _commit(
        'account.register',
        id,
        {
          'accounts': [account.toJson()]
        },
        atMs: account.createdAtMs);
    return account;
  }

  BotRecord createBotDraft(
      {required Actor actor, required String id, required String displayName}) {
    _owner(actor);
    _newPrincipal(id);
    _displayName(displayName);
    final bot = BotRecord(
        id: id,
        ownerId: actor.id,
        displayName: displayName,
        draft: true,
        active: false,
        createdAtMs: _time);
    _commit(
        'bot.draft',
        actor.id,
        {
          'bots': [bot.toJson()]
        },
        atMs: bot.createdAtMs);
    return bot;
  }

  void _botAdmission(String ownerId) {
    final active = state._bots.values.where((b) => b.active && !b.draft);
    _quota(active.length, state.config.maxBots, '社区入驻机器人');
    _quota(active.where((b) => b.ownerId == ownerId).length,
        state.config.maxBotsPerOwner, '每 owner 入驻机器人');
  }

  BotRecord registerBot(
      {required Actor actor, required String id, required String displayName}) {
    _owner(actor);
    _id(id);
    _displayName(displayName);
    final previous = state._bots[id];
    if (previous != null) {
      _ownsBot(actor, previous);
      _require(!previous.active || previous.draft, 'conflict', '机器人已入驻');
    } else {
      _newPrincipal(id);
    }
    _botAdmission(actor.id);
    final bot = BotRecord(
        id: id,
        ownerId: actor.id,
        displayName: displayName,
        caps: previous?.caps ?? BotCapability.all,
        createdAtMs: previous?.createdAtMs ?? _time);
    _commit('bot.register', actor.id, {
      'bots': [bot.toJson()]
    });
    return bot;
  }

  BotRecord admitBot({required Actor actor, required String botId}) {
    final bot = _bot(botId);
    _ownsBot(actor, bot);
    return registerBot(actor: actor, id: botId, displayName: bot.displayName);
  }

  BotRecord retireBot({required Actor actor, required String botId}) {
    final bot = _bot(botId);
    _ownsBot(actor, bot);
    final updated = bot.copyWith(active: false, draft: false);
    final at = _time;
    _commit(
        'bot.retire',
        actor.id,
        {
          'bots': [updated.toJson()],
          'memberships': state._memberships.values
              .where((m) =>
                  m.principalId == botId &&
                  (m.status == 'joined' || m.status == 'pending'))
              .map((m) => MembershipRecord(
                      spaceId: m.spaceId,
                      principalId: botId,
                      status: 'left',
                      createdAtMs: at)
                  .toJson())
              .toList()
        },
        atMs: at);
    return updated;
  }

  BotRecord setBotCaps(
      {required Actor actor,
      required String botId,
      required Set<String> caps}) {
    final bot = _bot(botId);
    _ownsBot(actor, bot);
    _require(caps.every(BotCapability.all.contains), 'bad_request',
        '只支持内容能力，不能通过 cap 授予社交或管理操作');
    final updated = bot.copyWith(caps: caps);
    _commit('bot.caps', actor.id, {
      'bots': [updated.toJson()]
    });
    return updated;
  }

  void configureCommunity(
      {required Actor actor, required CommunityConfig config}) {
    _owner(actor);
    _require(actor.id == _communityOwner, 'forbidden', '仅社区 owner 可设置社区配额');
    _commit('community.configure', actor.id, {'config': config.toJson()});
  }

  PrincipalRecord principal(
      {required Actor actor, required String principalId}) {
    _auth(actor);
    return _principal(principalId);
  }

  AccountRecord account({required Actor actor, required String accountId}) {
    _auth(actor);
    return state._accounts[accountId] ?? _fail('not_found', '账户不存在');
  }

  List<BotRecord> bots({required Actor actor}) {
    _auth(actor);
    return List.unmodifiable(
        state._bots.values.where((b) => b.ownerId == actor.ownerId));
  }

  void addFriend(
      {required Actor actor,
      required String targetId,
      String? botId,
      String? idempotencyKey}) {
    _owner(actor);
    final payload = {'targetId': targetId, 'botId': botId};
    if (_retry(actor, 'friend.add', idempotencyKey, payload) != null) return;
    final subject = _socialSubject(actor, botId);
    final target = _principal(targetId);
    _require(target.active && !target.draft && subject != targetId,
        'bad_request', '好友对象无效');
    _require(!state._friends.contains(_pair(subject, targetId)), 'conflict',
        '已经是好友');
    _commit(
        'friend.add',
        actor.id,
        {
          'friends': [
            {'a': subject, 'b': targetId, 'enabled': true}
          ]
        },
        idempotencyKey: idempotencyKey,
        payload: payload);
  }

  void removeFriend(
      {required Actor actor,
      required String targetId,
      String? botId,
      String? idempotencyKey}) {
    _owner(actor);
    final payload = {'targetId': targetId, 'botId': botId};
    if (_retry(actor, 'friend.remove', idempotencyKey, payload) != null) return;
    final subject = _socialSubject(actor, botId);
    _principal(targetId);
    _commit(
        'friend.remove',
        actor.id,
        {
          'friends': [
            {'a': subject, 'b': targetId, 'enabled': false}
          ]
        },
        idempotencyKey: idempotencyKey,
        payload: payload);
  }

  String _socialSubject(Actor actor, String? botId) {
    if (botId == null) return actor.id;
    final bot = _bot(botId);
    _ownsBot(actor, bot);
    _require(bot.active && !bot.draft, 'forbidden', '机器人尚未入驻');
    return bot.id;
  }

  bool _friends(String a, String b) {
    if (state._friends.contains(_pair(a, b))) return true;
    final pa = _principal(a);
    final pb = _principal(b);
    return pa.ownerId == pb.ownerId ||
        state._friends.contains(_pair(pa.ownerId, pb.ownerId));
  }

  List<PrincipalRecord> friends({required Actor actor}) {
    _auth(actor);
    return List.unmodifiable([...state._accounts.keys, ...state._bots.keys]
        .where((id) =>
            id != actor.id &&
            _principal(id).active &&
            !_principal(id).draft &&
            _friends(actor.id, id))
        .map(_principal));
  }

  SpaceRecord createSpace(
      {required Actor actor,
      required String id,
      required String title,
      required bool publicChannel,
      SpaceConfig? config,
      RoomConfig? defaultRoomConfig,
      String? defaultRoomId,
      String? idempotencyKey}) {
    _owner(actor);
    final payload = {
      'id': id,
      'title': title,
      'publicChannel': publicChannel,
      'config': (config ?? SpaceConfig()).toJson(),
      'defaultRoomConfig': (defaultRoomConfig ?? RoomConfig()).toJson(),
      'defaultRoomId': defaultRoomId
    };
    final retry = _retry(actor, 'space.create', idempotencyKey, payload);
    if (retry != null) return SpaceRecord.fromJson(retry);
    _id(id);
    _id(title, 'title');
    _require(!state._spaces.containsKey(id), 'conflict', '空间编号已存在');
    _quota(state._spaces.length, state.config.maxSpaces, '社区空间');
    _quota(state._spaces.values.where((s) => s.ownerId == actor.id).length,
        state.config.maxSpacesPerOwner, '每 owner 空间');
    final roomId = defaultRoomId ?? '$id#main';
    _newRoomId(roomId);
    final at = _time;
    final space = SpaceRecord(
        id: id,
        title: title,
        ownerId: actor.id,
        publicChannel: publicChannel,
        defaultRoomId: roomId,
        config: config,
        createdAtMs: at);
    final room = RoomRecord(
        id: roomId,
        spaceId: id,
        title: title,
        kind: 'chat',
        shadowConversationId: '$roomId#shadow',
        config: defaultRoomConfig);
    final cs = _chatConversations(room);
    _commit(
        'space.create',
        actor.id,
        {
          'spaces': [space.toJson()],
          'rooms': [room.toJson()],
          'conversations': cs.map((c) => c.toJson()).toList(),
          'memberships': [
            MembershipRecord(
                    spaceId: id,
                    principalId: actor.id,
                    status: 'joined',
                    createdAtMs: at)
                .toJson()
          ]
        },
        atMs: at,
        idempotencyKey: idempotencyKey,
        payload: payload,
        result: space.toJson());
    return space;
  }

  void _newRoomId(String id) {
    _id(id);
    _require(
        !state._rooms.containsKey(id) &&
            !state._conversations.containsKey(id) &&
            !state._conversations.containsKey('$id#shadow'),
        'conflict',
        '房间或会话编号已存在');
  }

  List<ConversationRecord> _chatConversations(RoomRecord room) => [
        ConversationRecord(
            id: room.id,
            kind: 'chat',
            title: room.title,
            spaceId: room.spaceId,
            roomId: room.id),
        ConversationRecord(
            id: room.shadowConversationId!,
            kind: 'shadow',
            title: '${room.title} · 茶会',
            spaceId: room.spaceId,
            roomId: room.id,
            shadowOf: room.id)
      ];

  SpaceRecord _admin(Actor actor, String spaceId, {bool ownerOnly = false}) {
    _owner(actor);
    final space = _space(spaceId);
    _require(state._joined(spaceId, actor.id) && !_banned(spaceId, actor.id),
        'forbidden', '管理者必须是当前空间成员');
    _require(
        space.ownerId == actor.id ||
            (!ownerOnly && space.adminIds.contains(actor.id)),
        'forbidden',
        '缺少空间管理权限');
    return space;
  }

  RoomRecord createRoom(
      {required Actor actor,
      required String spaceId,
      required String id,
      required String title,
      String kind = 'chat',
      RoomConfig? config,
      String? idempotencyKey}) {
    _owner(actor);
    final payload = {
      'spaceId': spaceId,
      'id': id,
      'title': title,
      'kind': kind,
      'config': (config ?? RoomConfig()).toJson()
    };
    final retry = _retry(actor, 'room.create', idempotencyKey, payload);
    if (retry != null) return RoomRecord.fromJson(retry);
    final space = _admin(actor, spaceId);
    _id(title, 'title');
    _require(
        kind == 'chat' || kind == 'forum', 'bad_request', '房间只支持 chat/forum');
    _newRoomId(id);
    _quota(state._rooms.values.where((r) => r.spaceId == spaceId).length,
        space.config.maxRooms, '空间房间');
    final room = RoomRecord(
        id: id,
        spaceId: spaceId,
        title: title,
        kind: kind,
        shadowConversationId: kind == 'chat' ? '$id#shadow' : null,
        config: config);
    _commit(
        'room.create',
        actor.id,
        {
          'rooms': [room.toJson()],
          'conversations': kind == 'chat'
              ? _chatConversations(room).map((c) => c.toJson()).toList()
              : []
        },
        idempotencyKey: idempotencyKey,
        payload: payload,
        result: room.toJson());
    return room;
  }

  void configureSpace(
      {required Actor actor,
      required String spaceId,
      required SpaceConfig config}) {
    final space = _admin(actor, spaceId);
    _commit('space.configure', actor.id, {
      'spaces': [space.copyWith(config: config).toJson()]
    });
  }

  void configureRoom(
      {required Actor actor,
      required String roomId,
      required RoomConfig config}) {
    final room = _room(roomId);
    _admin(actor, room.spaceId);
    _commit('room.configure', actor.id, {
      'rooms': [room.copyWith(config: config).toJson()]
    });
  }

  void setSpaceAdmin(
      {required Actor actor,
      required String spaceId,
      required String accountId,
      required bool enabled}) {
    final space = _admin(actor, spaceId, ownerOnly: true);
    final target = _principal(accountId);
    _require(!target.isBot && state._joined(spaceId, accountId), 'bad_request',
        '管理员必须是已加入的主账户');
    final admins = {...space.adminIds};
    if (enabled) {
      admins.add(accountId);
    } else {
      admins.remove(accountId);
    }
    _commit('space.admin', actor.id, {
      'spaces': [space.copyWith(adminIds: admins).toJson()]
    });
  }

  void inviteToSpace(
      {required Actor actor,
      required String spaceId,
      required String principalId}) {
    _admin(actor, spaceId);
    final p = _principal(principalId);
    _require(p.active && !p.draft, 'bad_request', '邀请目标未入驻');
    _require(!_banned(spaceId, principalId), 'forbidden', '封禁目标不可邀请');
    _commit('space.invite', actor.id, {
      'invitations': [
        {'spaceId': spaceId, 'principalId': principalId, 'enabled': true}
      ]
    });
  }

  void _admission(SpaceRecord space, String id) {
    final p = _principal(id);
    _require(p.active && !p.draft, 'forbidden', '主体未入驻');
    _require(!_banned(space.id, id), 'forbidden', '主体或其 owner 已被空间封禁');
    final members = state._members(space.id);
    _quota(members.length, space.config.maxMembers, '空间成员');
    if (p.isBot) {
      _require(space.config.allowBots, 'forbidden', '空间禁止机器人加入');
      final bots = members.where((m) => _principal(m.principalId).isBot);
      _quota(bots.length, space.config.maxBots, '空间机器人');
      _quota(
          bots
              .where((m) => _principal(m.principalId).ownerId == p.ownerId)
              .length,
          space.config.maxBotsPerOwner,
          '空间每 owner 机器人');
    }
  }

  MembershipRecord joinSpace(
      {required Actor actor,
      required String spaceId,
      String? botId,
      bool invited = false,
      String? idempotencyKey}) {
    _owner(actor);
    final payload = {'spaceId': spaceId, 'botId': botId, 'invited': invited};
    final retry = _retry(actor, 'space.join', idempotencyKey, payload);
    if (retry != null) return MembershipRecord.fromJson(retry);
    final subject = _socialSubject(actor, botId);
    final space = _space(spaceId);
    final old = state._memberships[_scopeKey(spaceId, subject)];
    if (old?.status == 'joined') {
      if (idempotencyKey != null)
        _commit('space.join', actor.id, {},
            idempotencyKey: idempotencyKey,
            payload: payload,
            result: old!.toJson());
      return old!;
    }
    _admission(space, subject);
    final hasInvitation =
        state._invitations.contains(_scopeKey(spaceId, subject));
    _require(!invited || hasInvitation, 'forbidden', 'invited 不是授权凭据，需真实管理员邀请');
    final status = space.publicChannel || hasInvitation ? 'joined' : 'pending';
    final record = MembershipRecord(
        spaceId: spaceId,
        principalId: subject,
        status: status,
        createdAtMs: _time);
    _commit(
        'space.join',
        actor.id,
        {
          'memberships': [record.toJson()],
          'invitations': hasInvitation
              ? [
                  {'spaceId': spaceId, 'principalId': subject, 'enabled': false}
                ]
              : []
        },
        atMs: record.createdAtMs,
        idempotencyKey: idempotencyKey,
        payload: payload,
        result: record.toJson());
    return record;
  }

  void decideJoin(
      {required Actor actor,
      required String spaceId,
      required String principalId,
      required bool approve}) {
    final space = _admin(actor, spaceId);
    _require(!space.publicChannel, 'forbidden', '公开频道自助加入，管理员无审批权');
    final pending = state._memberships[_scopeKey(spaceId, principalId)];
    _require(pending?.status == 'pending', 'not_found', '没有待审批申请');
    if (approve) _admission(space, principalId);
    final record = MembershipRecord(
        spaceId: spaceId,
        principalId: principalId,
        status: approve ? 'joined' : 'rejected',
        createdAtMs: _time);
    _commit(
        'space.decideJoin',
        actor.id,
        {
          'memberships': [record.toJson()]
        },
        atMs: record.createdAtMs);
  }

  void leaveSpace(
      {required Actor actor, required String spaceId, String? botId}) {
    _owner(actor);
    final subject = _socialSubject(actor, botId);
    final space = _space(spaceId);
    _require(subject != space.ownerId, 'forbidden', '空间 owner 不可直接退出自己的空间');
    _removeMember(actor, space, subject, 'left');
  }

  void _removeMember(
      Actor actor, SpaceRecord space, String subject, String status,
      {JsonMap? extra}) {
    final old = state._memberships[_scopeKey(space.id, subject)];
    _require(old?.status == 'joined' || old?.status == 'pending', 'not_found',
        '主体不是空间成员或申请者');
    final admins = {...space.adminIds}..remove(subject);
    _commit('space.$status', actor.id, {
      'memberships': [
        MembershipRecord(
                spaceId: space.id,
                principalId: subject,
                status: status,
                createdAtMs: _time)
            .toJson()
      ],
      'spaces': [space.copyWith(adminIds: admins).toJson()],
      ...?extra
    });
  }

  void kick(
      {required Actor actor,
      required String spaceId,
      required String principalId}) {
    final space = _admin(actor, spaceId);
    _canModerate(actor, space, principalId);
    _removeMember(actor, space, principalId, 'kicked');
  }

  void _canModerate(Actor actor, SpaceRecord space, String target) {
    _principal(target);
    _require(
        target != space.ownerId &&
            (actor.id == space.ownerId || !space.adminIds.contains(target)),
        'forbidden',
        '不可管理 owner 或同级管理员');
  }

  void ban(
      {required Actor actor,
      required String spaceId,
      required String principalId,
      required bool banned,
      String? roomId}) {
    final space = _admin(actor, spaceId);
    _canModerate(actor, space, principalId);
    if (roomId != null)
      _require(_room(roomId).spaceId == spaceId, 'bad_request', '房间不属于空间');
    final scope = roomId ?? spaceId;
    final patch = <String, dynamic>{
      'bans': [
        {'scopeId': scope, 'principalId': principalId, 'enabled': banned}
      ]
    };
    if (roomId == null && banned) {
      final affected = state
          ._members(spaceId)
          .where((m) =>
              m.principalId == principalId ||
              _principal(m.principalId).ownerId == principalId)
          .map((m) => m.principalId)
          .toSet();
      patch['memberships'] = affected
          .map((id) => MembershipRecord(
                  spaceId: spaceId,
                  principalId: id,
                  status: 'banned',
                  createdAtMs: _time)
              .toJson())
          .toList();
      patch['spaces'] = [
        space
            .copyWith(adminIds: {...space.adminIds}..removeAll(affected))
            .toJson()
      ];
    }
    _commit('space.ban', actor.id, patch);
  }

  void mute(
      {required Actor actor,
      required String spaceId,
      required String principalId,
      int? untilMs,
      bool muted = true,
      String? roomId}) {
    final space = _admin(actor, spaceId);
    _canModerate(actor, space, principalId);
    if (roomId != null)
      _require(_room(roomId).spaceId == spaceId, 'bad_request', '房间不属于空间');
    _require(untilMs == null || untilMs >= 0, 'bad_request', '禁言截止时间不得为负');
    _commit('space.mute', actor.id, {
      'mutes': [
        {
          'scopeId': roomId ?? spaceId,
          'principalId': principalId,
          'untilMs': muted ? (untilMs ?? 0) : -1
        }
      ]
    });
  }

  bool _banned(String scope, String id) =>
      state._bans.contains(_scopeKey(scope, id)) ||
      state._bans.contains(_scopeKey(scope, _principal(id).ownerId));
  bool _muted(String scope, String id, int at) {
    bool applies(String who) {
      final until = state._mutes[_scopeKey(scope, who)];
      return until != null && (until == 0 || until > at);
    }

    return applies(id) || applies(_principal(id).ownerId);
  }

  void _memberRead(Actor actor, String spaceId) {
    _require(state._joined(spaceId, actor.id) && !_banned(spaceId, actor.id),
        'forbidden', '只有当前合法空间成员可读取');
  }

  bool _roomAllowed(Actor actor, RoomRecord room) =>
      !_banned(room.id, actor.id) &&
      (room.config.allowedPrincipalIds.isEmpty ||
          room.config.allowedPrincipalIds.contains(actor.id));
  void _roomRead(Actor actor, RoomRecord room) {
    _memberRead(actor, room.spaceId);
    _require(_roomAllowed(actor, room), 'forbidden', '没有房间读取权限');
  }

  List<SpaceRecord> discoverSpaces({required Actor actor}) {
    _auth(actor);
    return List.unmodifiable(state._spaces.values
        .where((s) => s.publicChannel && !_banned(s.id, actor.id)));
  }

  List<RoomRecord> rooms({required Actor actor, required String spaceId}) {
    _auth(actor);
    _space(spaceId);
    _memberRead(actor, spaceId);
    return List.unmodifiable(state._rooms.values
        .where((r) => r.spaceId == spaceId && _roomAllowed(actor, r)));
  }

  List<PrincipalRecord> members(
      {required Actor actor, required String spaceId}) {
    _auth(actor);
    _space(spaceId);
    _memberRead(actor, spaceId);
    return List.unmodifiable(
        state._members(spaceId).map((m) => _principal(m.principalId)));
  }

  List<MembershipRecord> joinRequests(
      {required Actor actor, required String spaceId}) {
    final space = _admin(actor, spaceId);
    _require(!space.publicChannel, 'forbidden', '频道没有待审批队列');
    return List.unmodifiable(state._memberships.values
        .where((m) => m.spaceId == spaceId && m.status == 'pending'));
  }

  bool _sharedSpace(String a, String b) => state._spaces.values.any((s) =>
      s.config.allowBotDirects &&
      state._joined(s.id, a) &&
      state._joined(s.id, b) &&
      !_banned(s.id, a) &&
      !_banned(s.id, b));
  bool _permission(String a, String b, int at) {
    final owners = {_principal(a).ownerId, _principal(b).ownerId};
    final grants =
        state._directPermissions[_pair(a, b)] ?? const <String, int>{};
    return owners.every((id) =>
        grants.containsKey(id) && (grants[id] == 0 || grants[id]! > at));
  }

  bool _directReachable(ConversationRecord conversation, int at) {
    final a = _principal(conversation.participantIds[0]);
    final b = _principal(conversation.participantIds[1]);
    if (!a.active || a.draft || !b.active || b.draft) return false;
    if (a.isBot && b.isBot)
      return _sharedSpace(a.id, b.id) || _permission(a.id, b.id, at);
    return _friends(a.id, b.id);
  }

  ConversationRecord directConversation(
      {required Actor actor,
      required String targetId,
      String? idempotencyKey}) {
    _auth(actor);
    final payload = {'targetId': targetId};
    final retry = _retry(actor, 'direct.create', idempotencyKey, payload);
    if (retry != null) return ConversationRecord.fromJson(retry);
    final target = _principal(targetId);
    _require(targetId != actor.id && target.active && !target.draft,
        'bad_request', '私聊对象无效');
    final pair = _pair(actor.id, targetId);
    final existing = state._directPairs[pair];
    if (existing != null) {
      final record = state._conversations[existing]!;
      if (idempotencyKey != null)
        _commit('direct.create', actor.id, {},
            idempotencyKey: idempotencyKey,
            payload: payload,
            result: record.toJson());
      return record;
    }
    final conversation = ConversationRecord(
        id: _next('dm'),
        kind: 'direct',
        title: '${_principal(actor.id).displayName} / ${target.displayName}',
        participantIds: [actor.id, targetId]..sort());
    final at = _time;
    _require(_directReachable(conversation, at), 'forbidden',
        '缺少当前共同空间或双方 owner 显式许可/社交关系');
    final botPair = actor.isBot && target.isBot;
    final usage = <JsonMap>[];
    if (botPair) {
      _cap(actor, BotCapability.sendMessage);
      for (final id in conversation.participantIds) {
        _hourly('direct:$id', state.config.botDirectsPerHour, at);
        usage.add(_use('direct:$id', at));
      }
    }
    _commit(
        'direct.create',
        actor.id,
        {
          'conversations': [conversation.toJson()],
          'usage': usage
        },
        atMs: at,
        idempotencyKey: idempotencyKey,
        payload: payload,
        result: conversation.toJson());
    return conversation;
  }

  /// 每个 owner 只能设置自己这一票；不同 owner 必须分别调用，0 表示长期。
  void permitBotDirect(
      {required Actor actor,
      required String botId,
      required String targetBotId,
      bool allow = true,
      int untilMs = 0}) {
    final bot = _bot(botId);
    _ownsBot(actor, bot);
    final target = _bot(targetBotId);
    _require(
        bot.id != target.id &&
            bot.active &&
            target.active &&
            !bot.draft &&
            !target.draft,
        'bad_request',
        '机器人对无效');
    _nonNegative(untilMs);
    _require(untilMs == 0 || untilMs > _time, 'bad_request', '许可截止时间必须在未来');
    final existing = state._directPairs[_pair(botId, targetBotId)];
    _commit('direct.permission', actor.id, {
      'renewals': !allow && existing != null
          ? [
              {
                'conversationId': existing,
                'ownerId': actor.id,
                'generation': -1
              }
            ]
          : [],
      'directPermissions': [
        {
          'pair': _pair(botId, targetBotId),
          'ownerId': actor.id,
          'allow': allow,
          'untilMs': untilMs
        }
      ]
    });
  }

  /// 对当前轮次的续期需双方 owner 同意；单方不会恢复可达性或重置次数。
  void renewDirect({required Actor actor, required String conversationId}) {
    _owner(actor);
    final c = _conversation(conversationId);
    _require(
        c.kind == 'direct' &&
            c.participantIds.every((id) => _principal(id).isBot),
        'bad_request',
        '仅机器人闺房支持续期');
    final owners = c.participantIds.map((id) => _principal(id).ownerId).toSet();
    _require(owners.contains(actor.id), 'forbidden', '只有参与机器人的 owner 可投票');
    final generation = state._directGeneration[c.id] ?? 0;
    final votes = {...?state._renewalApprovals[c.id], actor.id: generation};
    final accepted = owners.every((id) => votes[id] == generation);
    _commit('direct.renew', actor.id, {
      'renewals': [
        {'conversationId': c.id, 'ownerId': actor.id, 'generation': generation}
      ],
      'directPermissions': accepted
          ? owners
              .map((id) => {
                    'pair': _pair(c.participantIds[0], c.participantIds[1]),
                    'ownerId': id,
                    'allow': true,
                    'untilMs': 0
                  })
              .toList()
          : [],
      'directResets': accepted
          ? [
              {
                'conversationId': c.id,
                'generation': generation + 1,
                'messageCount': state._conversationMessages(c.id).length
              }
            ]
          : []
    });
  }

  void _readConversation(Actor actor, ConversationRecord c) {
    _cap(actor, BotCapability.readHistory);
    if (c.kind == 'direct') {
      final participant = c.participantIds.contains(actor.id);
      final observer = !actor.isBot &&
          c.participantIds.every((id) => _principal(id).isBot) &&
          c.participantIds.any((id) => _principal(id).ownerId == actor.id);
      _require(participant || observer, 'forbidden', '不是私聊参与者或合法 owner 只读旁观者');
      return;
    }
    final room = _room(c.roomId!);
    _require(state._hasReadWindow(room.id, actor.id), 'forbidden',
        '没有当前或曾获准的房间历史资格');
    if (c.kind == 'forumThread') {
      final post = state._forumPosts[c.postId]!;
      _require(state._messageReadable(post.messageId, actor.id), 'forbidden',
          '帖子不在曾获准历史区间');
      _require(!state._hidden.contains(_scopeKey('forum', c.postId!)),
          'forbidden', '帖子已被内容管理隐藏');
    }
  }

  bool canReadConversation(
      {required Actor actor, required String conversationId}) {
    _auth(actor);
    try {
      _readConversation(actor, _conversation(conversationId));
      return true;
    } on DomainException catch (e) {
      if (e.code == 'forbidden' || e.code == 'not_found') return false;
      rethrow;
    }
  }

  List<ConversationRecord> conversations({required Actor actor}) {
    _auth(actor);
    return List.unmodifiable(state._conversations.values
        .where((c) => canReadConversation(actor: actor, conversationId: c.id)));
  }

  List<JsonMap> _messageWrite(Actor actor, ConversationRecord c, int at) {
    _cap(actor, BotCapability.sendMessage);
    final usage = <JsonMap>[];
    if (actor.isBot) {
      _hourly('message:${actor.id}', state.config.botMessagesPerHour, at);
      usage.add(_use('message:${actor.id}', at));
    }
    if (c.kind == 'direct') {
      _require(c.participantIds.contains(actor.id), 'forbidden',
          'owner 是只读旁观者，不是闺房参与者');
      _require(_directReachable(c, at), 'forbidden', '当前关系不可达，历史保留但禁止新写入');
      if (c.participantIds.every((id) => _principal(id).isBot)) {
        final count = state._conversationMessages(c.id).length -
            (state._directReset[c.id] ?? 0);
        _require(
            state.config.maxDirectMessages == 0 ||
                count < state.config.maxDirectMessages,
            'rate_limited',
            '闺房已达最大消息次数，需双方 owner 续期');
      }
      return usage;
    }
    final room = _room(c.roomId!);
    _roomRead(actor, room);
    final space = _space(room.spaceId);
    _require(!room.config.readOnly, 'forbidden', '房间只读');
    _require(!_muted(space.id, actor.id, at) && !_muted(room.id, actor.id, at),
        'forbidden', '主体被禁言');
    if (actor.isBot)
      _require(space.config.allowBotMessages && room.config.allowBotMessages,
          'forbidden', '房间或空间禁止机器人发言');
    if (c.kind == 'shadow') _require(actor.isBot, 'forbidden', '人类在茶会只能读取');
    if (c.kind == 'forumThread')
      _require(!state._hidden.contains(_scopeKey('forum', c.postId!)),
          'forbidden', '帖子已隐藏');
    final roomKey = _scopeKey('room-message', _scopeKey(room.id, actor.id));
    _hourly(roomKey, room.config.messagesPerHour, at);
    final slow = space.config.slowModeMs > room.config.slowModeMs
        ? space.config.slowModeMs
        : room.config.slowModeMs;
    _slow(roomKey, slow, at);
    usage.add(_use(roomKey, at));
    return usage;
  }

  MessageRecord sendMessage(
      {required Actor actor,
      required String conversationId,
      required List<JsonMap> parts,
      String? idempotencyKey}) {
    _auth(actor);
    final payload = {'conversationId': conversationId, 'parts': parts};
    final retry = _retry(actor, 'message.send', idempotencyKey, payload);
    if (retry != null) return MessageRecord.fromJson(retry);
    _content(parts);
    final c = _conversation(conversationId);
    _require(c.kind != 'forumThread', 'bad_request',
        '论坛回复请使用 replyForumPost，保留帖子语义');
    final at = _time;
    final usage = _messageWrite(actor, c, at);
    final record = MessageRecord(
        id: _next('message'),
        conversationId: c.id,
        senderId: actor.id,
        parts: parts,
        createdAtMs: at);
    _commit(
        'message.send',
        actor.id,
        {
          'messages': [record.toJson()],
          'usage': usage
        },
        atMs: at,
        idempotencyKey: idempotencyKey,
        payload: payload,
        result: record.toJson());
    return record;
  }

  List<MessageRecord> messages(
      {required Actor actor,
      required String conversationId,
      int limit = 50,
      String? beforeId}) {
    _auth(actor);
    final c = _conversation(conversationId);
    _readConversation(actor, c);
    _require(limit >= 1 && limit <= 1000, 'bad_request', 'limit 必须介于 1 和 1000');
    final all = state
        ._conversationMessages(conversationId)
        .where((message) =>
            c.kind == 'direct' || state._messageReadable(message.id, actor.id))
        .where((message) =>
            !state._hidden.contains(_scopeKey('message', message.id)))
        .toList();
    var end = all.length;
    if (beforeId != null) {
      final i = all.indexWhere((m) => m.id == beforeId);
      _require(i >= 0, 'not_found', '游标消息不属于该会话');
      end = i;
    }
    final start = end > limit ? end - limit : 0;
    return List.unmodifiable(all
        .sublist(start, end)
        .where((m) => !state._hidden.contains(_scopeKey('message', m.id))));
  }

  MessageRecord message({required Actor actor, required String messageId}) {
    _auth(actor);
    final msg = state._messages[messageId] ?? _fail('not_found', '消息不存在');
    final conversation = _conversation(msg.conversationId);
    _readConversation(actor, conversation);
    _require(
        conversation.kind == 'direct' ||
            state._messageReadable(messageId, actor.id),
        'forbidden',
        '消息不在曾获准历史区间');
    _require(!state._hidden.contains(_scopeKey('message', messageId)),
        'not_found', '消息已隐藏');
    return msg;
  }

  ForumPostRecord createForumPost(
      {required Actor actor,
      required String roomId,
      required String title,
      required List<JsonMap> parts,
      String? idempotencyKey}) {
    _auth(actor);
    final payload = {'roomId': roomId, 'title': title, 'parts': parts};
    final retry = _retry(actor, 'forum.post', idempotencyKey, payload);
    if (retry != null) return ForumPostRecord.fromJson(retry);
    _cap(actor, BotCapability.post);
    _content(parts);
    _id(title, 'title');
    final room = _room(roomId);
    _require(room.kind == 'forum', 'bad_request', '该房间不是论坛');
    final postId = _next('post');
    final conversation = ConversationRecord(
        id: _next('thread'),
        kind: 'forumThread',
        title: title,
        spaceId: room.spaceId,
        roomId: room.id,
        postId: postId);
    final at = _time;
    final usage = _messageWrite(actor, conversation, at);
    final key = _scopeKey('room-post', _scopeKey(roomId, actor.id));
    _hourly(key, room.config.postsPerHour, at);
    usage.add(_use(key, at));
    if (actor.isBot) {
      _hourly('post:${actor.id}', state.config.botPostsPerHour, at);
      usage.add(_use('post:${actor.id}', at));
    }
    final msg = MessageRecord(
        id: _next('message'),
        conversationId: conversation.id,
        senderId: actor.id,
        parts: parts,
        createdAtMs: at);
    final post = ForumPostRecord(
        id: postId,
        roomId: roomId,
        conversationId: conversation.id,
        authorId: actor.id,
        title: title,
        messageId: msg.id,
        createdAtMs: at);
    _commit(
        'forum.post',
        actor.id,
        {
          'conversations': [conversation.toJson()],
          'messages': [msg.toJson()],
          'forumPosts': [post.toJson()],
          'usage': usage
        },
        atMs: at,
        idempotencyKey: idempotencyKey,
        payload: payload,
        result: post.toJson());
    return post;
  }

  MessageRecord replyForumPost(
      {required Actor actor,
      required String postId,
      required List<JsonMap> parts,
      String? idempotencyKey}) {
    _auth(actor);
    final payload = {'postId': postId, 'parts': parts};
    final retry = _retry(actor, 'forum.reply', idempotencyKey, payload);
    if (retry != null) return MessageRecord.fromJson(retry);
    _cap(actor, BotCapability.reply);
    _content(parts);
    final post = state._forumPosts[postId] ?? _fail('not_found', '帖子不存在');
    _readConversation(actor, _conversation(post.conversationId));
    final at = _time;
    final usage = _messageWrite(actor, _conversation(post.conversationId), at);
    final msg = MessageRecord(
        id: _next('message'),
        conversationId: post.conversationId,
        senderId: actor.id,
        parts: parts,
        createdAtMs: at);
    _commit(
        'forum.reply',
        actor.id,
        {
          'messages': [msg.toJson()],
          'usage': usage
        },
        atMs: at,
        idempotencyKey: idempotencyKey,
        payload: payload,
        result: msg.toJson());
    return msg;
  }

  List<ForumPostRecord> forumPosts(
      {required Actor actor, required String roomId}) {
    _auth(actor);
    _cap(actor, BotCapability.readHistory);
    final room = _room(roomId);
    _require(room.kind == 'forum', 'bad_request', '不是论坛房间');
    _require(state._hasReadWindow(room.id, actor.id), 'forbidden',
        '没有当前或曾获准的房间历史资格');
    return List.unmodifiable(state._forumPosts.values.where((p) =>
        p.roomId == roomId &&
        state._messageReadable(p.messageId, actor.id) &&
        !state._hidden.contains(_scopeKey('forum', p.id))));
  }

  FeedPostRecord publishFeed(
      {required Actor actor,
      required List<JsonMap> parts,
      String visibility = 'friends',
      String? idempotencyKey}) {
    _auth(actor);
    final payload = {'parts': parts, 'visibility': visibility};
    final retry = _retry(actor, 'feed.post', idempotencyKey, payload);
    if (retry != null) return FeedPostRecord.fromJson(retry);
    _cap(actor, BotCapability.post);
    _content(parts);
    _require({'public', 'friends', 'private'}.contains(visibility),
        'bad_request', 'visibility 只支持 public/friends/private');
    final at = _time;
    final usage = <JsonMap>[];
    if (actor.isBot) {
      _hourly('post:${actor.id}', state.config.botPostsPerHour, at);
      usage.add(_use('post:${actor.id}', at));
    }
    final post = FeedPostRecord(
        id: _next('feed'),
        authorId: actor.id,
        visibility: visibility,
        parts: parts,
        createdAtMs: at);
    _commit(
        'feed.post',
        actor.id,
        {
          'feedPosts': [post.toJson()],
          'usage': usage
        },
        atMs: at,
        idempotencyKey: idempotencyKey,
        payload: payload,
        result: post.toJson());
    return post;
  }

  bool _feedVisible(Actor actor, FeedPostRecord post) {
    if (state._hidden.contains(_scopeKey('feed', post.id))) return false;
    if (post.authorId == actor.id) return true;
    if (!_principal(post.authorId).active) return false;
    if (post.visibility == 'private') return false;
    return post.visibility == 'public' || _friends(actor.id, post.authorId);
  }

  FeedPostRecord _readFeed(Actor actor, String id) {
    _cap(actor, BotCapability.readHistory);
    final post = state._feedPosts[id] ?? _fail('not_found', '朋友圈帖子不存在');
    _require(_feedVisible(actor, post), 'forbidden', '朋友圈帖子不可见');
    return post;
  }

  List<FeedPostRecord> feed(
      {required Actor actor,
      String? authorId,
      int limit = 50,
      String? beforeId}) {
    _auth(actor);
    _cap(actor, BotCapability.readHistory);
    _require(limit > 0 && limit <= 1000, 'bad_request', 'limit 必须介于 1 和 1000');
    final visible = state._feedPosts.values
        .toList()
        .reversed
        .where((p) =>
            (authorId == null || p.authorId == authorId) &&
            _feedVisible(actor, p))
        .toList();
    var start = 0;
    if (beforeId != null) {
      final i = visible.indexWhere((p) => p.id == beforeId);
      _require(i >= 0, 'not_found', '不可见或不存在的游标');
      start = i + 1;
    }
    return List.unmodifiable(visible.skip(start).take(limit));
  }

  FeedPostRecord feedPost({required Actor actor, required String postId}) {
    _auth(actor);
    return _readFeed(actor, postId);
  }

  FeedCommentRecord commentFeed(
      {required Actor actor,
      required String postId,
      required List<JsonMap> parts,
      String? idempotencyKey}) {
    _auth(actor);
    final payload = {'postId': postId, 'parts': parts};
    final retry = _retry(actor, 'feed.comment', idempotencyKey, payload);
    if (retry != null) return FeedCommentRecord.fromJson(retry);
    _cap(actor, BotCapability.reply);
    _content(parts);
    _readFeed(actor, postId);
    final at = _time;
    final usage = <JsonMap>[];
    if (actor.isBot) {
      _hourly('message:${actor.id}', state.config.botMessagesPerHour, at);
      usage.add(_use('message:${actor.id}', at));
    }
    final comment = FeedCommentRecord(
        id: _next('comment'),
        postId: postId,
        authorId: actor.id,
        parts: parts,
        createdAtMs: at);
    _commit(
        'feed.comment',
        actor.id,
        {
          'feedComments': [comment.toJson()],
          'usage': usage
        },
        atMs: at,
        idempotencyKey: idempotencyKey,
        payload: payload,
        result: comment.toJson());
    return comment;
  }

  List<FeedCommentRecord> feedComments(
      {required Actor actor, required String postId}) {
    _auth(actor);
    _readFeed(actor, postId);
    return List.unmodifiable(state._feedComments.values.where((c) =>
        c.postId == postId &&
        !state._hidden.contains(_scopeKey('comment', c.id))));
  }

  void likeFeed(
      {required Actor actor,
      required String postId,
      bool liked = true,
      String? idempotencyKey}) {
    _auth(actor);
    final payload = {'postId': postId, 'liked': liked};
    if (_retry(actor, 'feed.like', idempotencyKey, payload) != null) return;
    _cap(actor, BotCapability.like);
    _readFeed(actor, postId);
    _commit(
        'feed.like',
        actor.id,
        {
          'likes': [
            {'postId': postId, 'principalId': actor.id, 'liked': liked}
          ]
        },
        idempotencyKey: idempotencyKey,
        payload: payload);
  }

  Set<String> feedLikes({required Actor actor, required String postId}) {
    _auth(actor);
    _readFeed(actor, postId);
    return Set.unmodifiable(state._likes[postId] ?? <String>{});
  }

  /// 内容管理只增添隐藏事件，不改写或删除原始消息、帖子、评论。
  void hideContent(
      {required Actor actor,
      required String kind,
      required String contentId,
      bool hidden = true}) {
    _owner(actor);
    if (kind == 'message') {
      final msg = state._messages[contentId] ?? _fail('not_found', '消息不存在');
      final c = _conversation(msg.conversationId);
      _require(c.spaceId != null, 'forbidden', '私聊消息不提供管理删除/撤回');
      _admin(actor, c.spaceId!);
    } else if (kind == 'forum') {
      final post = state._forumPosts[contentId] ?? _fail('not_found', '帖子不存在');
      _admin(actor, _room(post.roomId).spaceId);
    } else if (kind == 'feed' || kind == 'comment') {
      _require(actor.id == _communityOwner, 'forbidden', '仅社区 owner 可屏蔽朋友圈内容');
      _require(
          kind == 'feed'
              ? state._feedPosts.containsKey(contentId)
              : state._feedComments.containsKey(contentId),
          'not_found',
          '内容不存在');
    } else {
      _fail('bad_request', '未知内容类型');
    }
    _commit('content.hide', actor.id, {
      'hidden': [
        {'kind': kind, 'id': contentId, 'hidden': hidden}
      ]
    });
  }
}
