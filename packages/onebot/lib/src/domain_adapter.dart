import 'dart:async';

import 'package:zaizuo_domain/zaizuo_domain.dart' as domain;

import 'backend.dart';

typedef DomainSendHandler = FutureOr<domain.MessageRecord> Function({
  required domain.Actor actor,
  required String conversationId,
  required List<Map<String, dynamic>> parts,
});

typedef DomainCommandHandler = FutureOr<Map<String, dynamic>> Function(
    String operation, Map<String, dynamic> params);

/// 实际连接业务内核；不接收请求提供的 Actor，也不把 owner 的权限赋给 bot。
/// v11/v12 group_id 映射到具体可读 chat/shadow 会话，而非空间默认房间别名。
/// 论坛/朋友圈通过zaizuo.扩展显式访问；标准send_message不冒充论坛帖子语义。
class DomainOneBotBackend
    implements OneBotBackend, OneBotChannelBackend, OneBotSocialBackend {
  DomainOneBotBackend(domain.ChatService service,
      {required this.botId,
      this.sendHandler,
      this.serviceProvider,
      this.directResolver,
      this.commandHandler,
      Stream<domain.MessageRecord>? messageStream})
      : _initialService = service {
    final actor = this.service.actor(botId);
    if (!actor.isBot) throw ArgumentError('OneBot binding must name a bot');
    _subscription = (messageStream ?? service.messageEvents).listen((message) {
      if (_closed) return;
      try {
        final permitted =
            this.service.message(actor: _actor, messageId: message.id);
        final conversation =
            this.service.state.conversations[permitted.conversationId];
        if (conversation == null || conversation.kind == 'forumThread') return;
        _messages.add(_convert(permitted));
      } on domain.DomainException {
        // 每个固定 bot 独立执行读权限过滤，不透传其它会话或已隐藏的消息。
      }
    }, onError: (Object _) {
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

  BotMessage _convert(domain.MessageRecord message) {
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
        parts: message.parts,
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
  BotMessage getMessage(String messageId) => _translate(
      () => _convert(service.message(actor: _actor, messageId: messageId)));
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
        final record = await (sendHandler ?? service.sendMessage)(
            actor: _actor, conversationId: conversationId, parts: parts);
        return _convert(record);
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

  Map<String, dynamic> _socialMessage(domain.MessageRecord record) => {
        'message_id': record.id,
        'conversation_id': record.conversationId,
        'user_id': record.senderId,
        'message': record.parts,
        'time': record.createdAtMs / 1000,
      };

  Map<String, dynamic> _forumJson(domain.ForumPostRecord post,
      {bool ownWrite = false}) {
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
      'message': original.parts,
      'time': post.createdAtMs / 1000,
      'replies': messages
          .where((value) => value.id != post.messageId)
          .map(_socialMessage)
          .toList(),
      'zaizuo.reply_window': 50,
    };
  }

  Map<String, dynamic> _feedComment(domain.FeedCommentRecord comment) => {
        'comment_id': comment.id,
        'post_id': comment.postId,
        'author_id': comment.authorId,
        'message': comment.parts,
        'time': comment.createdAtMs / 1000,
      };

  Map<String, dynamic> _feedJson(domain.FeedPostRecord post,
      {bool ownWrite = false}) {
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
      'message': post.parts,
      'time': post.createdAtMs / 1000,
      'comments': comments.skip(start).map(_feedComment).toList(),
      'likes': likes,
      'zaizuo.comments_truncated': start > 0,
    };
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
        final id = commandHandler == null
            ? service
                .createForumPost(
                    actor: _actor,
                    roomId: roomId,
                    title: title,
                    parts: parts,
                    idempotencyKey: idempotencyKey)
                .id
            : _resultId(await commandHandler!('forum.post', {
                'room': roomId,
                'title': title,
                'parts': parts,
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
        final id = commandHandler == null
            ? service
                .replyForumPost(
                    actor: _actor,
                    postId: postId,
                    parts: parts,
                    idempotencyKey: idempotencyKey)
                .id
            : _resultId(await commandHandler!('forum.reply', {
                'post': postId,
                'parts': parts,
                if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
              }));
        final message = service.message(actor: _actor, messageId: id);
        final post = service.state.forumPosts[postId];
        if (post == null || post.conversationId != message.conversationId) {
          throw const OneBotFailure(
              'internal', 'Command result is not a reply to this post');
        }
        _sentByBoundBot(message.senderId);
        return {'post_id': postId, ..._socialMessage(message)};
      });

  @override
  List<Map<String, dynamic>> getPosts(
          {required String roomId, int limit = 50, String? beforeId}) =>
      _translate(() {
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
        return visible.skip(start).take(limit).map(_forumJson).toList();
      });

  @override
  Future<Map<String, dynamic>> postFeed(
          {required List<Map<String, dynamic>> parts,
          String visibility = 'friends',
          String? idempotencyKey}) =>
      _translateAsync(() async {
        _actor;
        final id = commandHandler == null
            ? service
                .publishFeed(
                    actor: _actor,
                    parts: parts,
                    visibility: visibility,
                    idempotencyKey: idempotencyKey)
                .id
            : _resultId(await commandHandler!('feed.post', {
                'parts': parts,
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
  List<Map<String, dynamic>> getFeed(
          {String? authorId,
          String? postId,
          int limit = 50,
          String? beforeId}) =>
      _translate(() {
        if (limit < 1 || limit > 100) {
          throw const OneBotFailure(
              'bad_param', 'Feed list limit must be 1..100');
        }
        if (postId != null)
          return [_feedJson(service.feedPost(actor: _actor, postId: postId))];
        return service
            .feed(
                actor: _actor,
                authorId: authorId,
                limit: limit,
                beforeId: beforeId)
            .map(_feedJson)
            .toList();
      });

  @override
  Future<Map<String, dynamic>> commentFeed(
          {required String postId,
          required List<Map<String, dynamic>> parts,
          String? idempotencyKey}) =>
      _translateAsync(() async {
        _actor;
        final id = commandHandler == null
            ? service
                .commentFeed(
                    actor: _actor,
                    postId: postId,
                    parts: parts,
                    idempotencyKey: idempotencyKey)
                .id
            : _resultId(await commandHandler!('feed.comment', {
                'post': postId,
                'parts': parts,
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
    await _messages.close();
  }
}
