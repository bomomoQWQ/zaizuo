part of '../zaizuo_domain.dart';

String _pair(String a, String b) => _canonical([a, b]..sort());
String _scopeKey(String scope, String principal) =>
    _canonical([scope, principal]);

final class _ReadWindow {
  final int start;
  int? end;
  _ReadWindow(this.start);
  bool contains(int position) =>
      position >= start && (end == null || position < end!);
}

/// 本地可序列化业务状态。对外只提供不可变记录和只读索引。
/// 持久化格式以事件为真相，派生索引全部由 fromJson 重建；不是验签入口。
final class ChatState {
  final CommunityConfig _initialConfig;
  final String? communityOwnerId;
  CommunityConfig _config;
  final List<DomainEvent> _events = [];
  final Map<String, AccountRecord> _accounts = {};
  final Map<String, BotRecord> _bots = {};
  final Map<String, SpaceRecord> _spaces = {};
  final Map<String, RoomRecord> _rooms = {};
  final Map<String, ConversationRecord> _conversations = {};
  final Map<String, MessageRecord> _messages = {};
  final Map<String, ForumPostRecord> _forumPosts = {};
  final Map<String, FeedPostRecord> _feedPosts = {};
  final Map<String, FeedCommentRecord> _feedComments = {};
  final Map<String, MembershipRecord> _memberships = {};
  final Map<String, String> _names = {};
  final Map<String, String> _directPairs = {};
  final Set<String> _friends = {};
  final Set<String> _invitations = {};
  final Set<String> _bans = {};
  final Map<String, int> _mutes = {};
  final Set<String> _hidden = {};
  final Map<String, Set<String>> _likes = {};
  final Map<String, JsonMap> _idempotency = {};
  final Map<String, List<int>> _usage = {};
  final Map<String, Map<String, int>> _directPermissions = {};
  final Map<String, Map<String, int>> _renewalApprovals = {};
  final Map<String, int> _directGeneration = {};
  final Map<String, int> _directReset = {};
  final Map<String, List<_ReadWindow>> _readWindows = {};
  final Map<String, int> _messagePositions = {};
  final Map<String, int> _roomPositions = {};

  ChatState({CommunityConfig? config, this.communityOwnerId})
      : _initialConfig = config ?? CommunityConfig(),
        _config = config ?? CommunityConfig();

  CommunityConfig get config => _config;
  List<DomainEvent> get events => List.unmodifiable(_events);
  Map<String, AccountRecord> get accounts => UnmodifiableMapView(_accounts);
  Map<String, BotRecord> get bots => UnmodifiableMapView(_bots);
  Map<String, SpaceRecord> get spaces => UnmodifiableMapView(_spaces);
  Map<String, RoomRecord> get rooms => UnmodifiableMapView(_rooms);
  Map<String, ConversationRecord> get conversations =>
      UnmodifiableMapView(_conversations);
  Map<String, MessageRecord> get messages => UnmodifiableMapView(_messages);
  Map<String, ForumPostRecord> get forumPosts =>
      UnmodifiableMapView(_forumPosts);
  Map<String, FeedPostRecord> get feedPosts => UnmodifiableMapView(_feedPosts);
  Map<String, FeedCommentRecord> get feedComments =>
      UnmodifiableMapView(_feedComments);
  Map<String, MembershipRecord> get memberships =>
      UnmodifiableMapView(_memberships);

  factory ChatState.fromJson(JsonMap json) {
    try {
      _require(json['schemaVersion'] == 1, 'bad_request', '不支持的业务状态版本');
      final state = ChatState(
          config: CommunityConfig.fromJson(_jsonMap(json['initialConfig'])),
          communityOwnerId: json['communityOwnerId'] as String?);
      final ids = <String>{};
      for (final raw in json['events'] as List) {
        final event = DomainEvent.fromJson(_jsonMap(raw));
        _require(ids.add(event.id), 'bad_request', '事件编号重复');
        state._apply(event);
      }
      state._validate();
      return state;
    } on DomainException {
      rethrow;
    } catch (_) {
      _fail('bad_request', '无效的业务状态 JSON');
    }
  }

  JsonMap toJson() => {
        'schemaVersion': 1,
        'communityOwnerId': communityOwnerId,
        'initialConfig': _initialConfig.toJson(),
        'events': _events.map((e) => e.toJson()).toList()
      };

  void _validate() {
    _require(_accounts.length == _names.length, 'bad_request', '重复账户名');
    for (final account in _accounts.values) {
      _require(RegExp(r'^[a-z0-9_]{1,14}$').hasMatch(account.name),
          'bad_request', '无效的账户名');
      _displayName(account.displayName);
    }
    for (final event in _events) {
      _id(event.id);
      _require(_principalExists(event.actorId), 'bad_request', '事件作者不存在');
    }
    for (final bot in _bots.values) {
      _displayName(bot.displayName);
      _require(bot.caps.every(BotCapability.all.contains), 'bad_request',
          '无效机器人内容能力');
      _require(
          _accounts.containsKey(bot.ownerId) && !_accounts.containsKey(bot.id),
          'bad_request',
          '机器人必须有且仅有一个合法 owner');
    }
    for (final space in _spaces.values) {
      _require(
          _accounts.containsKey(space.ownerId) &&
              _rooms[space.defaultRoomId]?.spaceId == space.id,
          'bad_request',
          '空间 owner/默认房间不存在');
      _require(
          _joined(space.id, space.ownerId) &&
              space.adminIds.every(
                  (id) => _accounts.containsKey(id) && _joined(space.id, id)),
          'bad_request',
          '空间 owner/管理员必须是当前成员');
    }
    for (final room in _rooms.values) {
      _require(_spaces.containsKey(room.spaceId), 'bad_request', '房间空间不存在');
      _require(
          room.kind == 'chat' || room.kind == 'forum', 'bad_request', '无效房间类型');
      if (room.kind == 'chat') {
        _require(
            _conversations[room.id]?.kind == 'chat' &&
                _conversations[room.id]?.roomId == room.id,
            'bad_request',
            '聊天室缺少主会话');
        final shadows =
            _conversations.values.where((c) => c.shadowOf == room.id);
        _require(
            shadows.length == 1 &&
                shadows.single.id == room.shadowConversationId,
            'bad_request',
            '聊天室必须有唯一茶会');
      }
    }
    var directCount = 0;
    for (final c in _conversations.values.where((c) => c.kind == 'direct')) {
      directCount++;
      _require(
          c.participantIds.length == 2 &&
              c.participantIds[0] != c.participantIds[1] &&
              c.participantIds.every(_principalExists),
          'bad_request',
          '无效私聊参与者');
    }
    _require(directCount == _directPairs.length, 'bad_request', '同一对主体存在重复私聊');
    for (final c in _conversations.values) {
      _require({'direct', 'chat', 'shadow', 'forumThread'}.contains(c.kind),
          'bad_request', '无效会话类型');
      if (c.kind != 'direct')
        _require(
            _rooms[c.roomId]?.spaceId == c.spaceId, 'bad_request', '会话房间引用无效');
      if (c.kind == 'shadow')
        _require(
            c.shadowOf == c.roomId &&
                _rooms[c.roomId]?.shadowConversationId == c.id,
            'bad_request',
            '无效茶会引用');
      if (c.kind == 'forumThread')
        _require(_forumPosts[c.postId]?.conversationId == c.id, 'bad_request',
            '无效论坛会话引用');
    }
    for (final post in _forumPosts.values) {
      _require(
          _rooms[post.roomId]?.kind == 'forum' &&
              _messages[post.messageId]?.conversationId ==
                  post.conversationId &&
              _principalExists(post.authorId),
          'bad_request',
          '无效论坛帖子引用');
    }
    for (final member in _memberships.values) {
      _require(
          {'joined', 'pending', 'left', 'rejected', 'kicked', 'banned'}
              .contains(member.status),
          'bad_request',
          '无效成员状态');
      _require(
          _spaces.containsKey(member.spaceId) &&
              _principalExists(member.principalId),
          'bad_request',
          '无效成员引用');
    }
    for (final msg in _messages.values) {
      _require(
          _conversations.containsKey(msg.conversationId) &&
              _principalExists(msg.senderId),
          'bad_request',
          '无效消息引用');
    }
    for (final post in _feedPosts.values) {
      _require(
          _principalExists(post.authorId) &&
              {'public', 'friends', 'private'}.contains(post.visibility),
          'bad_request',
          '无效朋友圈引用');
    }
    for (final comment in _feedComments.values) {
      _require(
          _feedPosts.containsKey(comment.postId) &&
              _principalExists(comment.authorId),
          'bad_request',
          '无效评论引用');
    }
  }

  bool _principalExists(String id) =>
      _accounts.containsKey(id) || _bots.containsKey(id);
  bool _joined(String spaceId, String id) =>
      _memberships[_scopeKey(spaceId, id)]?.status == 'joined';
  List<MembershipRecord> _members(String spaceId) => _memberships.values
      .where((m) => m.spaceId == spaceId && m.status == 'joined')
      .toList();
  List<MessageRecord> _conversationMessages(String id) =>
      _messages.values.where((m) => m.conversationId == id).toList();

  Set<String> _eligibleReaders(RoomRecord room) {
    bool banned(String scope, String id, String owner) =>
        _bans.contains(_scopeKey(scope, id)) ||
        _bans.contains(_scopeKey(scope, owner));
    return _members(room.spaceId)
        .where((member) {
          final id = member.principalId;
          final bot = _bots[id];
          final owner = bot?.ownerId ?? id;
          return (bot == null || (bot.active && !bot.draft)) &&
              !banned(room.spaceId, id, owner) &&
              !banned(room.id, id, owner) &&
              (room.config.allowedPrincipalIds.isEmpty ||
                  room.config.allowedPrincipalIds.contains(id));
        })
        .map((m) => m.principalId)
        .toSet();
  }

  void _refreshReadWindows(int position) {
    for (final room in _rooms.values) {
      final eligible = _eligibleReaders(room);
      final space = _spaces[room.spaceId]!;
      for (final id in [..._accounts.keys, ..._bots.keys]) {
        final key = _scopeKey(room.id, id);
        final windows = _readWindows[key];
        final current =
            windows != null && windows.isNotEmpty && windows.last.end == null
                ? windows.last
                : null;
        if (eligible.contains(id) && current == null) {
          // 再次加入不补领中间缺席时段；开放历史只用于首次领取。
          final start = (windows == null || windows.isEmpty) &&
                  space.config.historyVisibleToNewMembers
              ? (_roomPositions[room.id] ?? position)
              : position;
          _readWindows.putIfAbsent(key, () => []).add(_ReadWindow(start));
        } else if (!eligible.contains(id) && current != null) {
          current.end = position;
        }
      }
    }
  }

  bool _hasReadWindow(String roomId, String principalId) =>
      _readWindows[_scopeKey(roomId, principalId)]?.isNotEmpty ?? false;
  bool _positionReadable(String roomId, String principalId, int position) =>
      (_readWindows[_scopeKey(roomId, principalId)] ?? const <_ReadWindow>[])
          .any((window) => window.contains(position));
  bool _messageReadable(String messageId, String principalId) {
    final message = _messages[messageId];
    if (message == null) return false;
    final conversation = _conversations[message.conversationId];
    if (conversation?.roomId == null) return false;
    return _positionReadable(
        conversation!.roomId!, principalId, _messagePositions[messageId]!);
  }

  void _apply(DomainEvent event) {
    final position = _events.length;
    final d = event.data;
    for (final raw in d['accounts'] as List? ?? const []) {
      final item = AccountRecord.fromJson(_jsonMap(raw));
      _require(!_accounts.containsKey(item.id), 'bad_request', '账户原事件不允许覆盖');
      _accounts[item.id] = item;
      _names[item.name.toLowerCase()] = item.id;
    }
    for (final raw in d['bots'] as List? ?? const []) {
      final item = BotRecord.fromJson(_jsonMap(raw));
      _require(
          _bots[item.id] == null || _bots[item.id]!.ownerId == item.ownerId,
          'bad_request',
          '机器人 owner 不可转移');
      _bots[item.id] = item;
    }
    for (final raw in d['spaces'] as List? ?? const []) {
      final item = SpaceRecord.fromJson(_jsonMap(raw));
      _spaces[item.id] = item;
    }
    for (final raw in d['rooms'] as List? ?? const []) {
      final item = RoomRecord.fromJson(_jsonMap(raw));
      _roomPositions.putIfAbsent(item.id, () => position);
      _rooms[item.id] = item;
    }
    for (final raw in d['conversations'] as List? ?? const []) {
      final item = ConversationRecord.fromJson(_jsonMap(raw));
      _require(!_conversations.containsKey(item.id), 'bad_request', '会话不允许被覆盖');
      _conversations[item.id] = item;
      if (item.kind == 'direct')
        _directPairs[_pair(item.participantIds[0], item.participantIds[1])] =
            item.id;
    }
    for (final raw in d['messages'] as List? ?? const []) {
      final item = MessageRecord.fromJson(_jsonMap(raw));
      _require(!_messages.containsKey(item.id), 'bad_request', '原消息事件不可覆盖');
      _messagePositions[item.id] = position;
      _messages[item.id] = item;
    }
    for (final raw in d['forumPosts'] as List? ?? const []) {
      final item = ForumPostRecord.fromJson(_jsonMap(raw));
      _require(!_forumPosts.containsKey(item.id), 'bad_request', '论坛原帖不可覆盖');
      _forumPosts[item.id] = item;
    }
    for (final raw in d['feedPosts'] as List? ?? const []) {
      final item = FeedPostRecord.fromJson(_jsonMap(raw));
      _require(!_feedPosts.containsKey(item.id), 'bad_request', '朋友圈原帖不可覆盖');
      _feedPosts[item.id] = item;
    }
    for (final raw in d['feedComments'] as List? ?? const []) {
      final item = FeedCommentRecord.fromJson(_jsonMap(raw));
      _require(
          !_feedComments.containsKey(item.id), 'bad_request', '朋友圈原评论不可覆盖');
      _feedComments[item.id] = item;
    }
    for (final raw in d['memberships'] as List? ?? const []) {
      final item = MembershipRecord.fromJson(_jsonMap(raw));
      _memberships[_scopeKey(item.spaceId, item.principalId)] = item;
    }
    for (final raw in d['friends'] as List? ?? const []) {
      final j = _jsonMap(raw);
      final key = _pair(j['a'] as String, j['b'] as String);
      if (j['enabled'] == true) {
        _friends.add(key);
      } else {
        _friends.remove(key);
      }
    }
    for (final raw in d['invitations'] as List? ?? const []) {
      final j = _jsonMap(raw);
      final key = _scopeKey(j['spaceId'] as String, j['principalId'] as String);
      if (j['enabled'] == true) {
        _invitations.add(key);
      } else {
        _invitations.remove(key);
      }
    }
    for (final raw in d['bans'] as List? ?? const []) {
      final j = _jsonMap(raw);
      final key = _scopeKey(j['scopeId'] as String, j['principalId'] as String);
      if (j['enabled'] == true) {
        _bans.add(key);
      } else {
        _bans.remove(key);
      }
    }
    for (final raw in d['mutes'] as List? ?? const []) {
      final j = _jsonMap(raw);
      _mutes[_scopeKey(j['scopeId'] as String, j['principalId'] as String)] =
          j['untilMs'] as int;
    }
    for (final raw in d['hidden'] as List? ?? const []) {
      final j = _jsonMap(raw);
      final key = _scopeKey(j['kind'] as String, j['id'] as String);
      if (j['hidden'] == true) {
        _hidden.add(key);
      } else {
        _hidden.remove(key);
      }
    }
    for (final raw in d['likes'] as List? ?? const []) {
      final j = _jsonMap(raw);
      final ids = _likes.putIfAbsent(j['postId'] as String, () => <String>{});
      if (j['liked'] == true) {
        ids.add(j['principalId'] as String);
      } else {
        ids.remove(j['principalId'] as String);
      }
    }
    for (final raw in d['usage'] as List? ?? const []) {
      final j = _jsonMap(raw);
      _usage.putIfAbsent(j['key'] as String, () => []).add(j['atMs'] as int);
    }
    for (final raw in d['directPermissions'] as List? ?? const []) {
      final j = _jsonMap(raw);
      final owners =
          _directPermissions.putIfAbsent(j['pair'] as String, () => {});
      if (j['allow'] == true) {
        owners[j['ownerId'] as String] = j['untilMs'] as int;
      } else {
        owners.remove(j['ownerId']);
      }
    }
    for (final raw in d['renewals'] as List? ?? const []) {
      final j = _jsonMap(raw);
      _renewalApprovals.putIfAbsent(
              j['conversationId'] as String, () => {})[j['ownerId'] as String] =
          j['generation'] as int;
    }
    for (final raw in d['directResets'] as List? ?? const []) {
      final j = _jsonMap(raw);
      final id = j['conversationId'] as String;
      _directGeneration[id] = j['generation'] as int;
      _directReset[id] = j['messageCount'] as int;
    }
    if (d['config'] != null)
      _config = CommunityConfig.fromJson(_jsonMap(d['config']));
    if (d['idempotency'] != null) {
      final j = _jsonMap(d['idempotency']);
      _idempotency[j['scope'] as String] = _immutableMap(j);
    }
    _refreshReadWindows(position);
    _events.add(event);
  }
}
