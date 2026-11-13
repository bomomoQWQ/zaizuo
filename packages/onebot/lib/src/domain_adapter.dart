import 'dart:async';
import 'dart:collection';

import 'package:zaizuo_domain/zaizuo_domain.dart' as domain;

import 'backend.dart';
import 'media.dart';

typedef DomainSendHandler = FutureOr<domain.MessageRecord> Function({
  required domain.Actor actor,
  required String conversationId,
  required List<Map<String, dynamic>> parts,
});

typedef DomainCommandHandler = FutureOr<Map<String, dynamic>> Function(
    String operation, Map<String, dynamic> params);
typedef DomainMediaUploadHandler = FutureOr<Map<String, dynamic>> Function(
    {required domain.Actor actor,
    required String name,
    required List<int> bytes,
    required String mime,
    required String purpose});
typedef DomainMediaGetHandler = FutureOr<Map<String, dynamic>> Function(
    {required domain.Actor actor, required String fileId});
typedef DomainResolveMediaParts = FutureOr<List<Map<String, dynamic>>> Function(
    {required domain.Actor actor,
    required String conversationId,
    required List<Map<String, dynamic>> parts});
typedef DomainProjectMediaParts = FutureOr<List<Map<String, dynamic>>> Function(
    {required domain.Actor actor, required domain.MessageRecord message});
typedef DomainMediaScope = FutureOr<String> Function(
    {required domain.Actor actor,
    required String operation,
    required Map<String, dynamic> params});

/// 实际连接业务内核；不接收请求提供的 Actor，也不把 owner 的权限赋给 bot。
/// v11/v12 group_id 映射到具体可读 chat/shadow 会话，而非空间默认房间别名。
/// 论坛/朋友圈通过zaizuo.扩展显式访问；标准send_message不冒充论坛帖子语义。
class DomainOneBotBackend
    implements
        OneBotBackend,
        OneBotChannelBackend,
        OneBotSocialBackend,
        OneBotMediaBackend {
  DomainOneBotBackend(domain.ChatService service,
      {required this.botId,
      this.sendHandler,
      this.serviceProvider,
      this.directResolver,
      this.commandHandler,
      this.mediaUploadHandler,
      this.mediaGetHandler,
      this.resolveMediaParts,
      this.projectMediaParts,
      this.mediaScope,
      this.maxMediaBytes = oneBotDefaultMaxMediaBytes,
      this.maxPendingMediaEvents = 32,
      this.mediaOperationTimeout = const Duration(seconds: 30),
      Stream<domain.MessageRecord>? messageStream})
      : _initialService = service {
    if (maxMediaBytes < 1 ||
        maxPendingMediaEvents < 1 ||
        mediaOperationTimeout <= Duration.zero) {
      throw ArgumentError('Media limits must be positive');
    }
    final actor = this.service.actor(botId);
    if (!actor.isBot) throw ArgumentError('OneBot binding must name a bot');
    _subscription = (messageStream ?? service.messageEvents)
        .listen(_queueMessage, onError: (Object _) {
      _messages.addError(
          const OneBotFailure('unavailable', 'Domain event stream failed'));
    });
  }
  final domain.ChatService _initialService;
  final domain.ChatService Function()? serviceProvider;
  domain.ChatService get service => serviceProvider?.call() ?? _initialService;

  /// 可选持久化入口：先完成可信提交/写盘再返回，失败不可伪成功。
  final DomainSendHandler? sendHandler;

  /// 论坛/朋友圈写命令持久化入口；参数不含任意actor，自身绑定由宿主固定。
  /// 使用domain operation名与runtime白名单参数（room/post/parts等）。
  final DomainCommandHandler? commandHandler;
  final DomainMediaUploadHandler? mediaUploadHandler;
  final DomainMediaGetHandler? mediaGetHandler;
  final DomainResolveMediaParts? resolveMediaParts;
  final DomainProjectMediaParts? projectMediaParts;
  final DomainMediaScope? mediaScope;
  @override
  final int maxMediaBytes;
  final int maxPendingMediaEvents;
  final Duration mediaOperationTimeout;
  bool _mediaTimedOut = false;

  Future<T> _mediaCall<T>(FutureOr<T> Function() operation) async {
    if (_mediaTimedOut)
      throw const OneBotFailure(
          'unavailable', 'Media callback timed out; restart required');
    try {
      return await Future<T>.sync(operation).timeout(mediaOperationTimeout);
    } on TimeoutException {
      // 不能取消的trusted Future可能仍运行：永久fail-closed而非继续累积新工作。
      _mediaTimedOut = true;
      throw const OneBotFailure(
          'unavailable', 'Media callback timed out; outcome may be unknown');
    }
  }

  @override
  bool get mediaEnabled =>
      mediaUploadHandler != null &&
      mediaGetHandler != null &&
      resolveMediaParts != null &&
      projectMediaParts != null;
  final _pendingMessages = Queue<domain.MessageRecord>();
  bool _projectingMessages = false;
  Future<void>? _projectingTask;

  void _queueMessage(domain.MessageRecord message) {
    if (_closed) return;
    if (_pendingMessages.length >= maxPendingMediaEvents) {
      _messages.addError(const OneBotFailure(
          'rate_limited', 'Media event projection queue is full'));
      return;
    }
    _pendingMessages.add(message);
    if (!_projectingMessages) {
      _projectingTask = _drainMessages();
      unawaited(_projectingTask!);
    }
  }

  Future<void> _drainMessages() async {
    _projectingMessages = true;
    try {
      while (!_closed && _pendingMessages.isNotEmpty) {
        final message = _pendingMessages.removeFirst();
        try {
          final permitted =
              service.message(actor: _actor, messageId: message.id);
          final conversation =
              service.state.conversations[permitted.conversationId];
          if (conversation == null || conversation.kind == 'forumThread')
            continue;
          final converted = await _convertAsync(permitted);
          // await期间可能撤销权限，送达前再核对，不能先发不带附件再补。
          service.message(actor: _actor, messageId: message.id);
          if (!_closed) _messages.add(converted);
        } on domain.DomainException {
          // 当前固定bot不再有权读取，整条事件丢弃。
        } on OneBotFailure catch (error) {
          if (!_closed &&
              error.code != 'forbidden' &&
              error.code != 'not_found') {
            _messages.addError(error);
          }
        } catch (_) {
          if (!_closed)
            _messages.addError(
                const OneBotFailure('internal', 'Media projection failed'));
        }
      }
    } finally {
      _projectingMessages = false;
    }
  }

  @override
  Future<Map<String, dynamic>> uploadFile(
          {required String name,
          required List<int> bytes,
          required String mime,
          required String purpose}) =>
      _translateAsync(() async {
        if (!mediaEnabled)
          throw const OneBotFailure(
              'unsupported_action', 'Media backend is not installed');
        final actor = _actor;
        final caps = service.state.bots[botId]!.caps;
        if (!caps.contains(domain.BotCapability.sendMessage) &&
            !caps.contains(domain.BotCapability.post)) {
          throw const OneBotFailure(
              'forbidden', 'Bot has no media publishing capability');
        }
        if (bytes.length > maxMediaBytes)
          throw const OneBotFailure('bad_param', 'File is too large');
        final result = await _mediaCall(() => mediaUploadHandler!(
            actor: actor,
            name: sanitizeMediaName(name),
            bytes: List<int>.unmodifiable(bytes),
            mime: validateMediaMime(mime),
            purpose: validateMediaPurpose(purpose)));
        _actor;
        return {'file_id': validateOpaqueFileId(result['file_id'])};
      });

  @override
  Future<Map<String, dynamic>> getFile(String fileId) =>
      _translateAsync(() async {
        if (!mediaEnabled)
          throw const OneBotFailure(
              'unsupported_action', 'Media backend is not installed');
        final actor = _actor;
        if (!service.state.bots[botId]!.caps
            .contains(domain.BotCapability.readHistory)) {
          throw const OneBotFailure(
              'forbidden', 'Bot has no attachment reading capability');
        }
        final result = await _mediaCall(() => mediaGetHandler!(
            actor: actor, fileId: validateOpaqueFileId(fileId)));
        _actor;
        final bytes = decodeMediaBase64(result['data'], maxMediaBytes);
        if (result.containsKey('size') && result['size'] != bytes.length) {
          throw const OneBotFailure('internal', 'Media backend size mismatch');
        }
        return {
          'name': sanitizeMediaName(result['name']),
          'mime':
              validateMediaMime(result['mime'] ?? 'application/octet-stream'),
          'size': bytes.length,
          'data': result['data']
        };
      });

  /// 可先把 direct.create 持久化并保存独立会话密钥，再返回会话编号。
  final FutureOr<String> Function(String targetId)? directResolver;
  @override
  final String botId;
  domain.Actor get _actor {
    final actor = service.actor(botId);
    if (!actor.isBot) {
      throw const OneBotFailure(
          'forbidden', 'Bound identity is not an authorized bot');
    }
    return actor;
  }

  final _messages = StreamController<BotMessage>.broadcast(sync: true);
  late final StreamSubscription<domain.MessageRecord> _subscription;
  bool _closed = false;
  @override
  Stream<BotMessage> get messages => _messages.stream;

  T _translate<T>(T Function() action) {
    try {
      if (_closed)
        throw const OneBotFailure('unavailable', 'Domain adapter is closed');
      return action();
    } on domain.DomainException catch (error) {
      final code = switch (error.code) {
        'bad_request' => 'bad_request_domain',
        'conflict' || 'idempotency_conflict' => 'bad_param',
        'forbidden' ||
        'not_found' ||
        'rate_limited' ||
        'quota_exceeded' =>
          error.code,
        _ => 'internal',
      };
      // 核心错误 message 是业务文本，协议不回显内部状态/任意输入值。
      throw OneBotFailure(
          code,
          switch (code) {
            'forbidden' => 'Permission denied by domain policy',
            'not_found' => 'Domain object not found or not visible',
            'quota_exceeded' => 'Domain quota exceeded',
            'rate_limited' => 'Domain rate limit exceeded',
            'bad_request_domain' || 'bad_param' => 'Invalid domain operation',
            _ => 'Domain operation failed',
          });
    }
  }

  Future<T> _translateAsync<T>(FutureOr<T> Function() action) async {
    try {
      return await _translate(action);
    } on domain.DomainException catch (error) {
      // 异步持久化handler在await后抛出的domain错误仍走同一类型化映射。
      return _translate<T>(() => throw error);
    }
  }

  BotProfile _profile(domain.PrincipalRecord principal, {String? spaceId}) {
    final space = spaceId == null ? null : service.state.spaces[spaceId];
    final role = principal.id == space?.ownerId
        ? 'owner'
        : (space?.adminIds.contains(principal.id) ?? false)
            ? 'admin'
            : 'member';
    return BotProfile(
        id: principal.id,
        name: principal.isBot
            ? principal.displayName
            : service.account(actor: _actor, accountId: principal.id).name,
        displayName: principal.displayName,
        role: role);
  }

  bool _currentlyVisible(domain.ConversationRecord conversation) {
    if (conversation.spaceId == null || conversation.roomId == null)
      return false;
    try {
      return service
          .rooms(actor: _actor, spaceId: conversation.spaceId!)
          .any((room) => room.id == conversation.roomId);
    } on domain.DomainException catch (error) {
      if (error.code == 'forbidden' || error.code == 'not_found') return false;
      rethrow;
    }
  }

  domain.ConversationRecord _conversation(String groupId) {
    final conversation = service.state.conversations[groupId];
    if (conversation == null)
      throw const OneBotFailure('not_found', 'Unknown group');
    if (conversation.kind != 'chat' && conversation.kind != 'shadow') {
      throw const OneBotFailure(
          'unsupported_param', 'Conversation is not a chat group');
    }
    if (!_currentlyVisible(conversation) ||
        !service.canReadConversation(
            actor: _actor, conversationId: conversation.id)) {
      throw const OneBotFailure(
          'forbidden', 'Group is not readable by bound bot');
    }
    return conversation;
  }

  Future<List<Map<String, dynamic>>> _projectParts(
      domain.MessageRecord message) async {
    if (!hasMediaParts(message.parts)) return message.parts;
    if (!mediaEnabled)
      throw const OneBotFailure(
          'unsupported_segment', 'Media projection is not configured');
    final conversation = service.state.conversations[message.conversationId];
    final expectedScope = conversation?.kind == 'forumThread'
        ? conversation!.roomId
        : message.conversationId;
    for (final part in message.parts
        .where((part) => part['type'] == 'image' || part['type'] == 'file')) {
      final data = part['data'];
      final attachment = data is Map ? data['attachment'] : null;
      if (data is! Map ||
          data.length != 1 ||
          attachment is! Map ||
          attachment.length != 3 ||
          attachment['scope'] != expectedScope ||
          attachment['epoch'] is! int ||
          (attachment['epoch'] as int) < 1 ||
          attachment['descriptor'] is! Map) {
        throw const OneBotFailure('internal',
            'Committed media must contain a scoped encrypted attachment');
      }
    }
    final projected = await _mediaCall(
        () => projectMediaParts!(actor: _actor, message: message));
    if (projected.length != message.parts.length) {
      throw const OneBotFailure(
          'internal', 'Media projection changed message layout');
    }
    return List<Map<String, dynamic>>.generate(message.parts.length, (index) {
      final original = message.parts[index];
      if (original['type'] != 'image' && original['type'] != 'file')
        return original;
      final part = projected[index];
      if (part['type'] != original['type'] || part['data'] is! Map) {
        throw const OneBotFailure('internal', 'Invalid media projection');
      }
      return {
        'type': original['type'],
        'data': publicMediaData(part['data'] as Map)
      };
    }, growable: false);
  }

  Future<BotMessage> _convertAsync(domain.MessageRecord message) async =>
      _convert(message, parts: await _projectParts(message));

  Future<List<Map<String, dynamic>>> _resolveParts(
      String scope, List<Map<String, dynamic>> parts,
      {required bool allowOpaque}) async {
    if (!hasMediaParts(parts)) return parts;
    if (!mediaEnabled)
      throw const OneBotFailure(
          'unsupported_segment', 'Media sending is not configured');
    final resolved = await _mediaCall(() =>
        resolveMediaParts!(actor: _actor, conversationId: scope, parts: parts));
    if (resolved.length != parts.length) {
      throw const OneBotFailure(
          'internal', 'Media resolver changed message layout');
    }
    return List<Map<String, dynamic>>.generate(parts.length, (index) {
      final original = parts[index];
      if (original['type'] != 'image' && original['type'] != 'file')
        return original;
      final part = resolved[index];
      final data = part['data'];
      if (part['type'] != original['type'] || data is! Map) {
        throw const OneBotFailure(
            'internal', 'Invalid trusted media resolution');
      }
      if (!data.containsKey('attachment')) {
        // Node统一在execute里按当前epoch解析一次；trusted hook可保留opaque引用。
        // 仅宿主send/command handler存在时允许，不能默认domain把未解析ID当已发送附件。
        if (!allowOpaque ||
            data.keys
                .any((key) => !{'file_id', 'name', 'mime'}.contains(key))) {
          throw const OneBotFailure(
              'internal', 'Opaque media needs a trusted committing handler');
        }
        return {'type': original['type'], 'data': publicMediaData(data)};
      }
      if (data.length != 1 || data['attachment'] is! Map) {
        throw const OneBotFailure('internal', 'Invalid encrypted attachment');
      }
      final attachment = data['attachment'] as Map;
      if (attachment.length != 3 ||
          attachment['scope'] != scope ||
          attachment['epoch'] is! int ||
          (attachment['epoch'] as int) < 1 ||
          attachment['descriptor'] is! Map) {
        throw const OneBotFailure(
            'internal', 'Invalid encrypted attachment scope or epoch');
      }
      return {
        'type': original['type'],
        'data': {'attachment': Map<String, dynamic>.from(attachment)}
      };
    }, growable: false);
  }

  BotMessage _convert(domain.MessageRecord message,
      {List<Map<String, dynamic>>? parts}) {
    final conversation = service.state.conversations[message.conversationId];
    if (conversation == null)
      throw const OneBotFailure('not_found', 'Unknown conversation');
    if (conversation.kind == 'forumThread') {
      throw const OneBotFailure(
          'unsupported_param', 'Forum threads are not projected');
    }
    final direct = conversation.kind == 'direct';
    return BotMessage(
        id: message.id,
        conversationId: message.conversationId,
        sender: _profile(
            service.principal(actor: _actor, principalId: message.senderId),
            spaceId: conversation.spaceId),
        parts: parts ?? message.parts,
        createdAtMs: message.createdAtMs,
        detailType: direct ? 'private' : 'group',
        groupId: direct ? null : conversation.id,
        peerId: direct
            ? conversation.participantIds.firstWhere((id) => id != botId)
            : null,
        guildId: direct ? null : conversation.spaceId,
        channelId: direct ? null : conversation.id);
  }

  BotGroup _group(domain.ConversationRecord conversation) {
    final space = service.state.spaces[conversation.spaceId]!;
    return BotGroup(
        id: conversation.id,
        name: conversation.title,
        memberCount: _visibleMembers(conversation).length,
        maxMemberCount: space.config.maxMembers);
  }

  List<domain.PrincipalRecord> _visibleMembers(
      domain.ConversationRecord conversation) {
    final room = service.state.rooms[conversation.roomId]!;
    final allowed = room.config.allowedPrincipalIds;
    return service
        .members(actor: _actor, spaceId: conversation.spaceId!)
        .where((principal) => allowed.isEmpty || allowed.contains(principal.id))
        .toList();
  }

  @override
  BotProfile getSelf() => _translate(
      () => _profile(service.principal(actor: _actor, principalId: botId)));
  @override
  BotProfile getUser(String userId) => _translate(
      () => _profile(service.principal(actor: _actor, principalId: userId)));
  @override
  List<BotProfile> getFriends() => _translate(() => service
      .friends(actor: _actor)
      .map((principal) => _profile(principal))
      .toList());
  @override
  List<BotGroup> getGroups() => _translate(() => service
      .conversations(actor: _actor)
      .where((conversation) =>
          (conversation.kind == 'chat' || conversation.kind == 'shadow') &&
          _currentlyVisible(conversation))
      .map(_group)
      .toList());
  @override
  BotGroup getGroup(String groupId) =>
      _translate(() => _group(_conversation(groupId)));
  @override
  List<BotProfile> getGroupMembers(String groupId) => _translate(() {
        final conversation = _conversation(groupId);
        return _visibleMembers(conversation)
            .map((principal) =>
                _profile(principal, spaceId: conversation.spaceId))
            .toList();
      });
  @override
  Future<BotMessage> getMessage(String messageId) => _translateAsync(() async {
        final permitted = service.message(actor: _actor, messageId: messageId);
        final result = await _convertAsync(permitted);
        service.message(actor: _actor, messageId: messageId);
        return result;
      });
  @override
  Future<BotMessage> send(
          {required String detailType,
          required String targetId,
          required List<Map<String, dynamic>> parts}) =>
      _translateAsync(() async {
        final String conversationId;
        if (detailType == 'private') {
          conversationId = directResolver != null
              ? await directResolver!(targetId)
              : service
                  .directConversation(actor: _actor, targetId: targetId)
                  .id;
        } else if (detailType == 'group') {
          conversationId = _conversation(targetId).id;
        } else {
          throw const OneBotFailure(
              'unsupported_param', 'Unsupported conversation type');
        }
        if (hasMediaParts(parts)) {
          // domain没有只读写入检查API：在独立不可变快照上预检，不发布真状态/事件。
          final candidate = domain.ChatService(
              domain.ChatState.fromJson(service.state.toJson()));
          try {
            candidate.sendMessage(
                actor: candidate.actor(botId),
                conversationId: conversationId,
                parts: parts);
          } finally {
            await candidate.close();
          }
        }
        final resolved = await _resolveParts(conversationId, parts,
            allowOpaque: sendHandler != null);
        final record = await (sendHandler ?? service.sendMessage)(
            actor: _actor, conversationId: conversationId, parts: resolved);
        return await _convertAsync(record);
      });
  @override
  bool isOnline() {
    if (_closed) return false;
    try {
      return service.principal(actor: _actor, principalId: botId).active;
    } on domain.DomainException {
      return false;
    }
  }

  @override
  List<BotGroup> getGuilds() => _translate(() {
        final seen = <String>{};
        final result = <BotGroup>[];
        for (final conversation in service.conversations(actor: _actor)) {
          if ((conversation.kind == 'chat' || conversation.kind == 'shadow') &&
              conversation.spaceId != null &&
              _currentlyVisible(conversation) &&
              seen.add(conversation.spaceId!)) {
            result.add(getGuild(conversation.spaceId!));
          }
        }
        return result;
      });
  @override
  BotGroup getGuild(String guildId) => _translate(() {
        final members = service.members(actor: _actor, spaceId: guildId);
        final space = service.state.spaces[guildId]!;
        return BotGroup(
            id: space.id,
            name: space.title,
            memberCount: members.length,
            maxMemberCount: space.config.maxMembers);
      });
  @override
  List<BotChannel> getChannels(String guildId) => _translate(() {
        // rooms()负责合法空间成员检查；conversations负责房间交集与history.read能力。
        service.rooms(actor: _actor, spaceId: guildId);
        return service
            .conversations(actor: _actor)
            .where((value) =>
                value.spaceId == guildId &&
                _currentlyVisible(value) &&
                (value.kind == 'chat' || value.kind == 'shadow'))
            .map((value) =>
                BotChannel(id: value.id, name: value.title, guildId: guildId))
            .toList();
      });
  @override
  BotChannel getChannel(String guildId, String channelId) => _translate(() {
        final value = _conversation(channelId);
        if (value.spaceId != guildId) {
          throw const OneBotFailure(
              'not_found', 'Channel is not in the supplied guild');
        }
        return BotChannel(id: value.id, name: value.title, guildId: guildId);
      });
  @override
  Future<BotMessage> sendChannel(
          {required String guildId,
          required String channelId,
          required List<Map<String, dynamic>> parts}) =>
      _translateAsync(() {
        getChannel(guildId, channelId);
        return send(detailType: 'group', targetId: channelId, parts: parts);
      });

  Future<Map<String, dynamic>> _socialMessage(
          domain.MessageRecord record) async =>
      {
        'message_id': record.id,
        'conversation_id': record.conversationId,
        'user_id': record.senderId,
        'message': await _projectParts(record),
        'time': record.createdAtMs / 1000,
      };

  Future<Map<String, dynamic>> _forumJson(domain.ForumPostRecord post,
      {bool ownWrite = false}) async {
    // 新写入的自身回执不要求history.read，也不顺带读取旧回复；列表查询才按读权限取历史。
    final original = ownWrite
        ? service.state.messages[post.messageId]!
        : service.message(actor: _actor, messageId: post.messageId);
    if (ownWrite) _sentByBoundBot(original.senderId);
    final messages = ownWrite
        ? <domain.MessageRecord>[]
        : service.messages(
            actor: _actor, conversationId: post.conversationId, limit: 50);
    return {
      'post_id': post.id,
      'room_id': post.roomId,
      'conversation_id': post.conversationId,
      'author_id': post.authorId,
      'title': post.title,
      'message_id': post.messageId,
      'message': await _projectParts(original),
      'time': post.createdAtMs / 1000,
      'replies': await Future.wait(messages
          .where((value) => value.id != post.messageId)
          .map(_socialMessage)),
      'zaizuo.reply_window': 50,
    };
  }

  Future<Map<String, dynamic>> _feedComment(
          domain.FeedCommentRecord comment) async =>
      {
        'comment_id': comment.id,
        'post_id': comment.postId,
        'author_id': comment.authorId,
        'message': await _projectParts(domain.MessageRecord(
            id: comment.id,
            conversationId: _feedScope(comment.postId),
            senderId: comment.authorId,
            parts: comment.parts,
            createdAtMs: comment.createdAtMs)),
        'time': comment.createdAtMs / 1000,
      };

  String _feedScope(String postId) {
    final post = service.state.feedPosts[postId];
    if (post == null) throw const OneBotFailure('not_found', 'Unknown feed');
    return 'feed:${post.authorId}:${post.visibility}';
  }

  Future<Map<String, dynamic>> _feedJson(domain.FeedPostRecord post,
      {bool ownWrite = false}) async {
    if (ownWrite) _sentByBoundBot(post.authorId);
    final comments = ownWrite
        ? <domain.FeedCommentRecord>[]
        : service.feedComments(actor: _actor, postId: post.id);
    final start = comments.length > 50 ? comments.length - 50 : 0;
    final likes = ownWrite
        ? <String>[]
        : service.feedLikes(actor: _actor, postId: post.id).toList()
      ..sort();
    return {
      'post_id': post.id,
      'author_id': post.authorId,
      'visibility': post.visibility,
      'message': await _projectParts(domain.MessageRecord(
          id: post.id,
          conversationId: 'feed:${post.authorId}:${post.visibility}',
          senderId: post.authorId,
          parts: post.parts,
          createdAtMs: post.createdAtMs)),
      'time': post.createdAtMs / 1000,
      'comments': await Future.wait(comments.skip(start).map(_feedComment)),
      'likes': likes,
      'zaizuo.comments_truncated': start > 0,
    };
  }

  Future<List<Map<String, dynamic>>> _resolveSocial(String op,
      Map<String, dynamic> params, List<Map<String, dynamic>> parts) async {
    if (!hasMediaParts(parts)) return parts;
    if (!mediaEnabled)
      throw const OneBotFailure(
          'unsupported_segment', 'Social media is not configured');
    final candidate =
        domain.ChatService(domain.ChatState.fromJson(service.state.toJson()));
    try {
      final actor = candidate.actor(botId);
      switch (op) {
        case 'forum.post':
          candidate.createForumPost(
              actor: actor,
              roomId: params['room'] as String,
              title: params['title'] as String,
              parts: parts);
          break;
        case 'forum.reply':
          candidate.replyForumPost(
              actor: actor, postId: params['post'] as String, parts: parts);
          break;
        case 'feed.post':
          candidate.publishFeed(
              actor: actor,
              visibility: params['visibility'] as String,
              parts: parts);
          break;
        case 'feed.comment':
          candidate.commentFeed(
              actor: actor, postId: params['post'] as String, parts: parts);
          break;
      }
    } finally {
      await candidate.close();
    }
    final defaultScope = switch (op) {
      'forum.post' => params['room'] as String,
      'forum.reply' => service.state.forumPosts[params['post']]!.roomId,
      'feed.post' => 'feed:$botId:${params['visibility']}',
      'feed.comment' => _feedScope(params['post'] as String),
      _ => throw const OneBotFailure(
          'unsupported_param', 'Unknown social media scope'),
    };
    final scope = mediaScope == null
        ? defaultScope
        : await _mediaCall(
            () => mediaScope!(actor: _actor, operation: op, params: params));
    if (scope != defaultScope) {
      throw const OneBotFailure(
          'forbidden', 'Media scope does not match authorized target');
    }
    return _resolveParts(scope, parts, allowOpaque: commandHandler != null);
  }

  String _resultId(Map<String, dynamic> result) {
    final id = result['id'];
    if (id is! String || id.isEmpty) {
      throw const OneBotFailure(
          'internal', 'Command handler returned an invalid record');
    }
    return id;
  }

  void _sentByBoundBot(String senderId) {
    if (senderId != botId) {
      throw const OneBotFailure(
          'forbidden', 'Command result does not belong to bound bot');
    }
  }

  @override
  Future<Map<String, dynamic>> postForum(
          {required String roomId,
          required String title,
          required List<Map<String, dynamic>> parts,
          String? idempotencyKey}) =>
      _translateAsync(() async {
        _actor; // 即使启用runtime hook，也先验证当前固定bot仍合法。
        final resolved = await _resolveSocial(
            'forum.post', {'room': roomId, 'title': title}, parts);
        final id = commandHandler == null
            ? service
                .createForumPost(
                    actor: _actor,
                    roomId: roomId,
                    title: title,
                    parts: resolved,
                    idempotencyKey: idempotencyKey)
                .id
            : _resultId(await commandHandler!('forum.post', {
                'room': roomId,
                'title': title,
                'parts': resolved,
                if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
              }));
        final post = service.state.forumPosts[id];
        if (post == null || post.roomId != roomId || post.title != title) {
          throw const OneBotFailure(
              'internal', 'Command post was not committed to this room');
        }
        _sentByBoundBot(post.authorId);
        return _forumJson(post, ownWrite: true);
      });

  @override
  Future<Map<String, dynamic>> replyForum(
          {required String postId,
          required List<Map<String, dynamic>> parts,
          String? idempotencyKey}) =>
      _translateAsync(() async {
        _actor;
        final resolved =
            await _resolveSocial('forum.reply', {'post': postId}, parts);
        final id = commandHandler == null
            ? service
                .replyForumPost(
                    actor: _actor,
                    postId: postId,
                    parts: resolved,
                    idempotencyKey: idempotencyKey)
                .id
            : _resultId(await commandHandler!('forum.reply', {
                'post': postId,
                'parts': resolved,
                if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
              }));
        final message = service.message(actor: _actor, messageId: id);
        final post = service.state.forumPosts[postId];
        if (post == null || post.conversationId != message.conversationId) {
          throw const OneBotFailure(
              'internal', 'Command result is not a reply to this post');
        }
        _sentByBoundBot(message.senderId);
        return {'post_id': postId, ...await _socialMessage(message)};
      });

  @override
  Future<List<Map<String, dynamic>>> getPosts(
          {required String roomId, int limit = 50, String? beforeId}) =>
      _translateAsync(() async {
        if (limit < 1 || limit > 100) {
          throw const OneBotFailure(
              'bad_param', 'Forum list limit must be 1..100');
        }
        final visible =
            service.forumPosts(actor: _actor, roomId: roomId).reversed.toList();
        var start = 0;
        if (beforeId != null) {
          final index = visible.indexWhere((post) => post.id == beforeId);
          if (index < 0)
            throw const OneBotFailure(
                'not_found', 'Post cursor is not visible');
          start = index + 1;
        }
        final result = <Map<String, dynamic>>[];
        for (final post in visible.skip(start).take(limit)) {
          result.add(await _forumJson(post));
        }
        service.forumPosts(actor: _actor, roomId: roomId);
        return result;
      });

  @override
  Future<Map<String, dynamic>> postFeed(
          {required List<Map<String, dynamic>> parts,
          String visibility = 'friends',
          String? idempotencyKey}) =>
      _translateAsync(() async {
        _actor;
        final resolved = await _resolveSocial(
            'feed.post', {'visibility': visibility}, parts);
        final id = commandHandler == null
            ? service
                .publishFeed(
                    actor: _actor,
                    parts: resolved,
                    visibility: visibility,
                    idempotencyKey: idempotencyKey)
                .id
            : _resultId(await commandHandler!('feed.post', {
                'parts': resolved,
                'visibility': visibility,
                if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
              }));
        final post = service.state.feedPosts[id];
        if (post == null || post.visibility != visibility) {
          throw const OneBotFailure(
              'internal', 'Command feed post was not committed');
        }
        _sentByBoundBot(post.authorId);
        return _feedJson(post, ownWrite: true);
      });

  @override
  Future<List<Map<String, dynamic>>> getFeed(
          {String? authorId,
          String? postId,
          int limit = 50,
          String? beforeId}) =>
      _translateAsync(() async {
        if (limit < 1 || limit > 100) {
          throw const OneBotFailure(
              'bad_param', 'Feed list limit must be 1..100');
        }
        final posts = postId != null
            ? [service.feedPost(actor: _actor, postId: postId)]
            : service.feed(
                actor: _actor,
                authorId: authorId,
                limit: limit,
                beforeId: beforeId);
        final result = <Map<String, dynamic>>[];
        for (final post in posts) {
          result.add(await _feedJson(post));
          service.feedPost(actor: _actor, postId: post.id);
        }
        return result;
      });

  @override
  Future<Map<String, dynamic>> commentFeed(
          {required String postId,
          required List<Map<String, dynamic>> parts,
          String? idempotencyKey}) =>
      _translateAsync(() async {
        _actor;
        final resolved =
            await _resolveSocial('feed.comment', {'post': postId}, parts);
        final id = commandHandler == null
            ? service
                .commentFeed(
                    actor: _actor,
                    postId: postId,
                    parts: resolved,
                    idempotencyKey: idempotencyKey)
                .id
            : _resultId(await commandHandler!('feed.comment', {
                'post': postId,
                'parts': resolved,
                if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
              }));
        final comment = service
            .feedComments(actor: _actor, postId: postId)
            .where((value) => value.id == id)
            .firstOrNull;
        if (comment == null)
          throw const OneBotFailure(
              'not_found', 'Committed comment is not visible');
        _sentByBoundBot(comment.authorId);
        return _feedComment(comment);
      });

  @override
  Future<Map<String, dynamic>> likeFeed(
          {required String postId,
          bool liked = true,
          String? idempotencyKey}) =>
      _translateAsync(() async {
        _actor;
        if (commandHandler == null) {
          service.likeFeed(
              actor: _actor,
              postId: postId,
              liked: liked,
              idempotencyKey: idempotencyKey);
        } else {
          await commandHandler!('feed.like', {
            'post': postId,
            'liked': liked,
            if (idempotencyKey != null) 'idempotency_key': idempotencyKey
          });
        }
        final likes = service.feedLikes(actor: _actor, postId: postId);
        if (likes.contains(botId) != liked) {
          throw const OneBotFailure(
              'internal', 'Like command was not committed');
        }
        return {'post_id': postId, 'user_id': botId, 'liked': liked};
      });

  /// adapter不拥有ChatService，关闭时不关闭共享业务内核。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    _pendingMessages.clear();
    await _projectingTask;
    await _messages.close();
  }
}
