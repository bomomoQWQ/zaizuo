import 'package:zaizuo_domain/zaizuo_domain.dart';

/// 已验签、已绑定主体的原始命令重放白名单；不是签名验证或通道授权入口。
/// actorId 只能来自外层已验证事件，绝不从 params 中读取/覆盖。
Object? applyCommand(ChatService service, String actorId, String operation,
    Map<String, dynamic> p) {
  const fields = <String, Set<String>>{
    'message.send': {'conversation', 'parts', 'idempotency_key'},
    'bot.register': {'id', 'display_name'},
    'bot.draft': {'id', 'display_name'},
    'bot.admit': {'bot_id'},
    'bot.retire': {'bot_id'},
    'bot.caps': {'bot_id', 'caps'},
    'community.configure': {'config'},
    'space.create': {
      'id',
      'title',
      'public_channel',
      'config',
      'default_room_config',
      'default_room_id',
      'idempotency_key'
    },
    'space.configure': {'space', 'config'},
    'room.create': {
      'space',
      'id',
      'title',
      'kind',
      'config',
      'idempotency_key'
    },
    'room.configure': {'room', 'config'},
    'space.admin': {'space', 'account_id', 'enabled'},
    'space.invite': {'space', 'principal'},
    'space.join': {'space', 'bot_id', 'invited', 'idempotency_key'},
    'space.leave': {'space', 'bot_id'},
    'space.decide': {'space', 'principal', 'approve'},
    'space.kick': {'space', 'principal'},
    'space.ban': {'space', 'principal', 'banned', 'room'},
    'space.mute': {'space', 'principal', 'until_ms', 'muted', 'room'},
    'friend.add': {'target', 'bot_id', 'idempotency_key'},
    'friend.remove': {'target', 'bot_id', 'idempotency_key'},
    'direct.create': {'target', 'idempotency_key'},
    'direct.permission': {'bot_id', 'target_bot_id', 'allow', 'until_ms'},
    'direct.renew': {'conversation'},
    'forum.post': {'room', 'title', 'parts', 'idempotency_key'},
    'forum.reply': {'post', 'parts', 'idempotency_key'},
    'feed.post': {'parts', 'visibility', 'idempotency_key'},
    'feed.comment': {'post', 'parts', 'idempotency_key'},
    'feed.like': {'post', 'liked', 'idempotency_key'},
    'content.hide': {'kind', 'content_id', 'hidden'},
  };
  final allowed = fields[operation];
  if (allowed == null) {
    throw const DomainException('bad_request', '不支持的持久化命令');
  }
  final params = _Params(p, operation);
  params.only(allowed);
  // 这不是公开自报身份入口；上层须先验签并验证签名主体 == actorId。
  final actor = service.actor(actorId);
  String s(String key) => params.string(key);
  String? optional(String key) => params.optionalString(key);
  final key = optional('idempotency_key');
  switch (operation) {
    case 'message.send':
      return service.sendMessage(
          actor: actor,
          conversationId: s('conversation'),
          parts: params.parts(),
          idempotencyKey: key);
    case 'bot.register':
      return service.registerBot(
          actor: actor, id: s('id'), displayName: s('display_name'));
    case 'bot.draft':
      return service.createBotDraft(
          actor: actor, id: s('id'), displayName: s('display_name'));
    case 'bot.admit':
      return service.admitBot(actor: actor, botId: s('bot_id'));
    case 'bot.retire':
      return service.retireBot(actor: actor, botId: s('bot_id'));
    case 'bot.caps':
      return service.setBotCaps(
          actor: actor,
          botId: s('bot_id'),
          caps: params.strings('caps').toSet());
    case 'community.configure':
      service.configureCommunity(
          actor: actor, config: params.communityConfig('config'));
      return null;
    case 'space.create':
      return service.createSpace(
          actor: actor,
          id: s('id'),
          title: s('title'),
          publicChannel: params.boolean('public_channel'),
          config: params.has('config') ? params.spaceConfig('config') : null,
          defaultRoomConfig: params.has('default_room_config')
              ? params.roomConfig('default_room_config')
              : null,
          defaultRoomId: optional('default_room_id'),
          idempotencyKey: key);
    case 'space.configure':
      service.configureSpace(
          actor: actor,
          spaceId: s('space'),
          config: params.spaceConfig('config'));
      return null;
    case 'room.create':
      return service.createRoom(
          actor: actor,
          spaceId: s('space'),
          id: s('id'),
          title: s('title'),
          kind: params.enumString('kind', {'chat', 'forum'}, fallback: 'chat'),
          config: params.has('config') ? params.roomConfig('config') : null,
          idempotencyKey: key);
    case 'room.configure':
      service.configureRoom(
          actor: actor, roomId: s('room'), config: params.roomConfig('config'));
      return null;
    case 'space.admin':
      service.setSpaceAdmin(
          actor: actor,
          spaceId: s('space'),
          accountId: s('account_id'),
          enabled: params.boolean('enabled'));
      return null;
    case 'space.invite':
      service.inviteToSpace(
          actor: actor, spaceId: s('space'), principalId: s('principal'));
      return null;
    case 'space.join':
      return service.joinSpace(
          actor: actor,
          spaceId: s('space'),
          botId: optional('bot_id'),
          invited: params.boolean('invited', fallback: false),
          idempotencyKey: key);
    case 'space.leave':
      service.leaveSpace(
          actor: actor, spaceId: s('space'), botId: optional('bot_id'));
      return null;
    case 'space.decide':
      service.decideJoin(
          actor: actor,
          spaceId: s('space'),
          principalId: s('principal'),
          approve: params.boolean('approve'));
      return null;
    case 'space.kick':
      service.kick(
          actor: actor, spaceId: s('space'), principalId: s('principal'));
      return null;
    case 'space.ban':
      service.ban(
          actor: actor,
          spaceId: s('space'),
          principalId: s('principal'),
          banned: params.boolean('banned'),
          roomId: optional('room'));
      return null;
    case 'space.mute':
      service.mute(
          actor: actor,
          spaceId: s('space'),
          principalId: s('principal'),
          untilMs: params.optionalInteger('until_ms'),
          muted: params.boolean('muted', fallback: true),
          roomId: optional('room'));
      return null;
    case 'friend.add':
      service.addFriend(
          actor: actor,
          targetId: s('target'),
          botId: optional('bot_id'),
          idempotencyKey: key);
      return null;
    case 'friend.remove':
      service.removeFriend(
          actor: actor,
          targetId: s('target'),
          botId: optional('bot_id'),
          idempotencyKey: key);
      return null;
    case 'direct.create':
      return service.directConversation(
          actor: actor, targetId: s('target'), idempotencyKey: key);
    case 'direct.permission':
      service.permitBotDirect(
          actor: actor,
          botId: s('bot_id'),
          targetBotId: s('target_bot_id'),
          allow: params.boolean('allow', fallback: true),
          untilMs: params.integer('until_ms', fallback: 0));
      return null;
    case 'direct.renew':
      service.renewDirect(actor: actor, conversationId: s('conversation'));
      return null;
    case 'forum.post':
      return service.createForumPost(
          actor: actor,
          roomId: s('room'),
          title: s('title'),
          parts: params.parts(),
          idempotencyKey: key);
    case 'forum.reply':
      return service.replyForumPost(
          actor: actor,
          postId: s('post'),
          parts: params.parts(),
          idempotencyKey: key);
    case 'feed.post':
      return service.publishFeed(
          actor: actor,
          parts: params.parts(),
          visibility: params.enumString(
              'visibility', {'public', 'friends', 'private'},
              fallback: 'friends'),
          idempotencyKey: key);
    case 'feed.comment':
      return service.commentFeed(
          actor: actor,
          postId: s('post'),
          parts: params.parts(),
          idempotencyKey: key);
    case 'feed.like':
      service.likeFeed(
          actor: actor,
          postId: s('post'),
          liked: params.boolean('liked', fallback: true),
          idempotencyKey: key);
      return null;
    case 'content.hide':
      service.hideContent(
          actor: actor,
          kind: params
              .enumString('kind', {'message', 'forum', 'feed', 'comment'}),
          contentId: s('content_id'),
          hidden: params.boolean('hidden', fallback: true));
      return null;
    default:
      throw const DomainException('bad_request', '不支持的持久化命令');
  }
}

/// 只做JSON形状、已知字段与资源边界检查；业务权限仍由domain裁定。
final class _Params {
  final Map<String, dynamic> values;
  final String context;
  _Params(this.values, this.context);
  Never bad(String message) =>
      throw DomainException('bad_request', '$context: $message');
  bool has(String key) => values.containsKey(key);
  void only(Set<String> keys) {
    final unknown = values.keys.where((key) => !keys.contains(key));
    if (unknown.isNotEmpty) bad('未知参数 ${unknown.join(', ')}');
  }

  String string(String key) {
    final value = values[key];
    if (value is! String || value.trim().isEmpty || value.length > 512)
      bad('$key 必须为1–512字符的非空字符串');
    return value;
  }

  String? optionalString(String key) {
    if (!has(key) || values[key] == null) return null;
    return string(key);
  }

  bool boolean(String key, {bool? fallback}) {
    if (!has(key) && fallback != null) return fallback;
    final value = values[key];
    if (value is! bool) bad('$key 必须为布尔值');
    return value;
  }

  int integer(String key, {int? fallback}) {
    if (!has(key) && fallback != null) return fallback;
    final value = values[key];
    if (value is! int || value < 0 || value > 9007199254740991)
      bad('$key 必须为0–2^53-1的整数，0表示不限/长期');
    return value;
  }

  int? optionalInteger(String key) {
    if (!has(key) || values[key] == null) return null;
    return integer(key);
  }

  String enumString(String key, Set<String> allowed, {String? fallback}) {
    if (!has(key) && fallback != null) return fallback;
    final value = string(key);
    if (!allowed.contains(value)) bad('$key 不支持 $value');
    return value;
  }

  List<String> strings(String key) {
    final value = values[key];
    if (value is! List || value.length > 10000) bad('$key 必须为最多10000项字符串数组');
    final result = <String>[];
    for (final item in value) {
      if (item is! String || item.trim().isEmpty || item.length > 512)
        bad('$key 含无效字符串');
      result.add(item);
    }
    if (result.toSet().length != result.length) bad('$key 不允许重复项');
    return result;
  }

  _Params object(String key) {
    final value = values[key];
    if (value is! Map || value.keys.any((key) => key is! String))
      bad('$key 必须为JSON对象');
    return _Params(Map<String, dynamic>.from(value), '$context.$key');
  }

  List<Map<String, dynamic>> parts() {
    final value = values['parts'];
    if (value is! List || value.isEmpty || value.length > 1000)
      bad('parts 必须为1–1000项消息段数组');
    var nodes = 0;
    void jsonValue(Object? value, int depth) {
      nodes++;
      if (depth > 32 || nodes > 100000) bad('消息JSON过深或过大');
      if (value == null || value is bool || value is int) return;
      if (value is String) {
        if (value.length > 1048576) bad('单个文本值过大');
        return;
      }
      if (value is double && value.isFinite) return;
      if (value is List) {
        for (final item in value) {
          jsonValue(item, depth + 1);
        }
        return;
      }
      if (value is Map && value.keys.every((key) => key is String)) {
        for (final item in value.values) {
          jsonValue(item, depth + 1);
        }
        return;
      }
      bad('parts只能包含有限JSON值');
    }

    final result = <Map<String, dynamic>>[];
    for (final raw in value) {
      if (raw is! Map || raw.keys.any((key) => key is! String))
        bad('消息段必须为JSON对象');
      final segment = _Params(Map<String, dynamic>.from(raw), '$context.parts');
      segment.only({'type', 'data'});
      segment.string('type');
      if (segment.has('data')) segment.object('data');
      jsonValue(raw, 0);
      result.add(Map<String, dynamic>.from(raw));
    }
    return result;
  }

  CommunityConfig communityConfig(String key) {
    final c = object(key);
    c.only({
      'maxAccounts',
      'maxBots',
      'maxSpaces',
      'maxBotsPerOwner',
      'maxSpacesPerOwner',
      'botMessagesPerHour',
      'botPostsPerHour',
      'botDirectsPerHour',
      'maxDirectMessages'
    });
    return CommunityConfig(
        maxAccounts: c.integer('maxAccounts', fallback: 0),
        maxBots: c.integer('maxBots', fallback: 0),
        maxSpaces: c.integer('maxSpaces', fallback: 0),
        maxBotsPerOwner: c.integer('maxBotsPerOwner', fallback: 5),
        maxSpacesPerOwner: c.integer('maxSpacesPerOwner', fallback: 0),
        botMessagesPerHour: c.integer('botMessagesPerHour', fallback: 120),
        botPostsPerHour: c.integer('botPostsPerHour', fallback: 4),
        botDirectsPerHour: c.integer('botDirectsPerHour', fallback: 6),
        maxDirectMessages: c.integer('maxDirectMessages', fallback: 50));
  }

  SpaceConfig spaceConfig(String key) {
    final c = object(key);
    c.only({
      'maxMembers',
      'maxBots',
      'maxBotsPerOwner',
      'maxRooms',
      'allowBots',
      'allowBotMessages',
      'allowBotDirects',
      'historyVisibleToNewMembers',
      'slowModeMs'
    });
    return SpaceConfig(
        maxMembers: c.integer('maxMembers', fallback: 0),
        maxBots: c.integer('maxBots', fallback: 10),
        maxBotsPerOwner: c.integer('maxBotsPerOwner', fallback: 2),
        maxRooms: c.integer('maxRooms', fallback: 0),
        allowBots: c.boolean('allowBots', fallback: true),
        allowBotMessages: c.boolean('allowBotMessages', fallback: true),
        allowBotDirects: c.boolean('allowBotDirects', fallback: true),
        historyVisibleToNewMembers:
            c.boolean('historyVisibleToNewMembers', fallback: false),
        slowModeMs: c.integer('slowModeMs', fallback: 0));
  }

  RoomConfig roomConfig(String key) {
    final c = object(key);
    c.only({
      'allowedPrincipalIds',
      'readOnly',
      'allowBotMessages',
      'messagesPerHour',
      'postsPerHour',
      'slowModeMs'
    });
    return RoomConfig(
        allowedPrincipalIds: c.has('allowedPrincipalIds')
            ? c.strings('allowedPrincipalIds').toSet()
            : {},
        readOnly: c.boolean('readOnly', fallback: false),
        allowBotMessages: c.boolean('allowBotMessages', fallback: true),
        messagesPerHour: c.integer('messagesPerHour', fallback: 0),
        postsPerHour: c.integer('postsPerHour', fallback: 0),
        slowModeMs: c.integer('slowModeMs', fallback: 0));
  }
}
