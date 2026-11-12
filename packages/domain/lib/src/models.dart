part of '../zaizuo_domain.dart';

typedef JsonMap = Map<String, dynamic>;

/// 业务错误，不绑定 OneBot 的数字错误码。
final class DomainException implements Exception {
  final String code;
  final String message;
  const DomainException(this.code, this.message);
  @override
  String toString() => 'DomainException($code): $message';
}

Never _fail(String code, String message) =>
    throw DomainException(code, message);
void _require(bool condition, String code, String message) {
  if (!condition) _fail(code, message);
}

String _id(String value, [String label = 'id']) {
  _require(value.trim().isNotEmpty, 'bad_request', '$label 不得为空');
  return value;
}

void _displayName(String value) {
  _id(value, 'displayName');
  _require(
      value.characters.length < 15, 'bad_request', 'displayName 必须少于 15 个显示字符');
}

int _nonNegative(int value) {
  _require(value >= 0, 'bad_request', '上限/时长不得为负，0 表示不限');
  return value;
}

Object? _freeze(Object? value) {
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double && value.isFinite) return value;
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  if (value is Map) {
    _require(value.keys.every((key) => key is String), 'bad_request',
        'JSON 键必须为字符串');
    return Map<String, dynamic>.unmodifiable(
        value.map((key, item) => MapEntry(key as String, _freeze(item))));
  }
  _fail('bad_request', '数据必须为有限 JSON 值');
}

JsonMap _jsonMap(Object? value) {
  _require(value is Map, 'bad_request', '需要 JSON 对象');
  return Map<String, dynamic>.from(value as Map);
}

JsonMap _immutableMap(JsonMap value) => _freeze(value) as JsonMap;
List<String> _strings(Object? value) =>
    List<String>.unmodifiable((value as List? ?? const []).cast<String>());
Set<String> _stringSet(Object? value) =>
    Set<String>.unmodifiable(_strings(value));
List<JsonMap> _parts(Object? value) {
  _require(value is List, 'bad_request', 'parts 必须是消息段数组');
  return List<JsonMap>.unmodifiable(
      (value as List).map((item) => _immutableMap(_jsonMap(item))));
}

String _canonical(Object? value) {
  Object? sorted(Object? input) {
    if (input is Map) {
      final keys = input.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: sorted(input[key])};
    }
    if (input is List) return input.map(sorted).toList();
    return input;
  }

  return jsonEncode(sorted(_freeze(value)));
}

/// 构造器可用于序列化/展示，但手工构造的 Actor 不能执行服务操作。
/// 可信适配器先验证凭据，再用 service.actor(已绑定的编号) 领取会话句柄。
final class Actor {
  final String id;
  final String ownerId;
  final bool isBot;
  final Object? _serviceToken;
  const Actor({required this.id, required this.ownerId, required this.isBot})
      : _serviceToken = null;
  Actor._(this.id, this.ownerId, this.isBot, this._serviceToken);
  JsonMap toJson() => {'id': id, 'ownerId': ownerId, 'isBot': isBot};
}

final class AccountRecord {
  final String id;
  final String name;
  final String displayName;
  final int createdAtMs;
  const AccountRecord(
      {required this.id,
      required this.name,
      required this.displayName,
      required this.createdAtMs});
  factory AccountRecord.fromJson(JsonMap json) => AccountRecord(
      id: json['id'] as String,
      name: json['name'] as String,
      displayName: json['displayName'] as String,
      createdAtMs: json['createdAtMs'] as int);
  JsonMap toJson() => {
        'id': id,
        'name': name,
        'displayName': displayName,
        'createdAtMs': createdAtMs
      };
}

final class PrincipalRecord {
  final String id;
  final String ownerId;
  final bool isBot;
  final String displayName;
  final bool active;
  final bool draft;
  const PrincipalRecord(
      {required this.id,
      required this.ownerId,
      required this.isBot,
      required this.displayName,
      this.active = true,
      this.draft = false});
  JsonMap toJson() => {
        'id': id,
        'ownerId': ownerId,
        'isBot': isBot,
        'displayName': displayName,
        'active': active,
        'draft': draft
      };
}

/// 只允许内容能力；不存在能够赋予加好友/入群/管理的 capability。
abstract final class BotCapability {
  static const sendMessage = 'msg.send';
  static const readHistory = 'history.read';
  static const post = 'post.create';
  static const reply = 'post.reply';
  static const like = 'post.like';
  static const all = {sendMessage, readHistory, post, reply, like};
}

final class BotRecord {
  final String id;
  final String ownerId;
  final String displayName;
  final bool draft;
  final bool active;
  final Set<String> caps;
  final int createdAtMs;
  BotRecord(
      {required this.id,
      required this.ownerId,
      required this.displayName,
      this.draft = false,
      this.active = true,
      Set<String> caps = BotCapability.all,
      required this.createdAtMs})
      : caps = Set<String>.unmodifiable(caps);
  factory BotRecord.fromJson(JsonMap json) => BotRecord(
      id: json['id'] as String,
      ownerId: json['ownerId'] as String,
      displayName: json['displayName'] as String,
      draft: json['draft'] as bool? ?? false,
      active: json['active'] as bool? ?? true,
      caps: _stringSet(json['caps']),
      createdAtMs: json['createdAtMs'] as int);
  BotRecord copyWith({bool? draft, bool? active, Set<String>? caps}) =>
      BotRecord(
          id: id,
          ownerId: ownerId,
          displayName: displayName,
          draft: draft ?? this.draft,
          active: active ?? this.active,
          caps: caps ?? this.caps,
          createdAtMs: createdAtMs);
  PrincipalRecord get principal => PrincipalRecord(
      id: id,
      ownerId: ownerId,
      isBot: true,
      displayName: displayName,
      active: active,
      draft: draft);
  JsonMap toJson() => {
        'id': id,
        'ownerId': ownerId,
        'displayName': displayName,
        'draft': draft,
        'active': active,
        'caps': caps.toList()..sort(),
        'createdAtMs': createdAtMs
      };
}

/// 0 一律表示不限；仅约束本地已归并状态，不承诺跨设备全局强一致。
final class CommunityConfig {
  final int maxAccounts;
  final int maxBots;
  final int maxSpaces;
  final int maxBotsPerOwner;
  final int maxSpacesPerOwner;
  final int botMessagesPerHour;
  final int botPostsPerHour;
  final int botDirectsPerHour;
  final int maxDirectMessages;
  CommunityConfig(
      {this.maxAccounts = 0,
      this.maxBots = 0,
      this.maxSpaces = 0,
      this.maxBotsPerOwner = 5,
      this.maxSpacesPerOwner = 0,
      this.botMessagesPerHour = 120,
      this.botPostsPerHour = 4,
      this.botDirectsPerHour = 6,
      this.maxDirectMessages = 50}) {
    for (final number in [
      maxAccounts,
      maxBots,
      maxSpaces,
      maxBotsPerOwner,
      maxSpacesPerOwner,
      botMessagesPerHour,
      botPostsPerHour,
      botDirectsPerHour,
      maxDirectMessages
    ]) {
      _nonNegative(number);
    }
  }
  factory CommunityConfig.fromJson(JsonMap j) => CommunityConfig(
      maxAccounts: j['maxAccounts'] as int? ?? 0,
      maxBots: j['maxBots'] as int? ?? 0,
      maxSpaces: j['maxSpaces'] as int? ?? 0,
      maxBotsPerOwner: j['maxBotsPerOwner'] as int? ?? 5,
      maxSpacesPerOwner: j['maxSpacesPerOwner'] as int? ?? 0,
      botMessagesPerHour: j['botMessagesPerHour'] as int? ?? 120,
      botPostsPerHour: j['botPostsPerHour'] as int? ?? 4,
      botDirectsPerHour: j['botDirectsPerHour'] as int? ?? 6,
      maxDirectMessages: j['maxDirectMessages'] as int? ?? 50);
  JsonMap toJson() => {
        'maxAccounts': maxAccounts,
        'maxBots': maxBots,
        'maxSpaces': maxSpaces,
        'maxBotsPerOwner': maxBotsPerOwner,
        'maxSpacesPerOwner': maxSpacesPerOwner,
        'botMessagesPerHour': botMessagesPerHour,
        'botPostsPerHour': botPostsPerHour,
        'botDirectsPerHour': botDirectsPerHour,
        'maxDirectMessages': maxDirectMessages
      };
}

final class SpaceConfig {
  final int maxMembers;
  final int maxBots;
  final int maxBotsPerOwner;
  final int maxRooms;
  final bool allowBots;
  final bool allowBotMessages;
  final bool allowBotDirects;
  final bool historyVisibleToNewMembers;
  final int slowModeMs;
  SpaceConfig(
      {this.maxMembers = 0,
      this.maxBots = 10,
      this.maxBotsPerOwner = 2,
      this.maxRooms = 0,
      this.allowBots = true,
      this.allowBotMessages = true,
      this.allowBotDirects = true,
      this.historyVisibleToNewMembers = false,
      this.slowModeMs = 0}) {
    for (final n in [
      maxMembers,
      maxBots,
      maxBotsPerOwner,
      maxRooms,
      slowModeMs
    ]) {
      _nonNegative(n);
    }
  }
  factory SpaceConfig.fromJson(JsonMap j) => SpaceConfig(
      maxMembers: j['maxMembers'] as int? ?? 0,
      maxBots: j['maxBots'] as int? ?? 10,
      maxBotsPerOwner: j['maxBotsPerOwner'] as int? ?? 2,
      maxRooms: j['maxRooms'] as int? ?? 0,
      allowBots: j['allowBots'] as bool? ?? true,
      allowBotMessages: j['allowBotMessages'] as bool? ?? true,
      allowBotDirects: j['allowBotDirects'] as bool? ?? true,
      historyVisibleToNewMembers:
          j['historyVisibleToNewMembers'] as bool? ?? false,
      slowModeMs: j['slowModeMs'] as int? ?? 0);
  JsonMap toJson() => {
        'maxMembers': maxMembers,
        'maxBots': maxBots,
        'maxBotsPerOwner': maxBotsPerOwner,
        'maxRooms': maxRooms,
        'allowBots': allowBots,
        'allowBotMessages': allowBotMessages,
        'allowBotDirects': allowBotDirects,
        'historyVisibleToNewMembers': historyVisibleToNewMembers,
        'slowModeMs': slowModeMs
      };
}

final class RoomConfig {
  /// 空集合继承空间全部成员；非空为当前空间成员的进一步交集。
  final Set<String> allowedPrincipalIds;
  final bool readOnly;
  final bool allowBotMessages;
  final int messagesPerHour;
  final int postsPerHour;
  final int slowModeMs;
  RoomConfig(
      {Set<String> allowedPrincipalIds = const {},
      this.readOnly = false,
      this.allowBotMessages = true,
      this.messagesPerHour = 0,
      this.postsPerHour = 0,
      this.slowModeMs = 0})
      : allowedPrincipalIds = Set<String>.unmodifiable(allowedPrincipalIds) {
    for (final n in [messagesPerHour, postsPerHour, slowModeMs]) {
      _nonNegative(n);
    }
  }
  factory RoomConfig.fromJson(JsonMap j) => RoomConfig(
      allowedPrincipalIds: _stringSet(j['allowedPrincipalIds']),
      readOnly: j['readOnly'] as bool? ?? false,
      allowBotMessages: j['allowBotMessages'] as bool? ?? true,
      messagesPerHour: j['messagesPerHour'] as int? ?? 0,
      postsPerHour: j['postsPerHour'] as int? ?? 0,
      slowModeMs: j['slowModeMs'] as int? ?? 0);
  JsonMap toJson() => {
        'allowedPrincipalIds': allowedPrincipalIds.toList()..sort(),
        'readOnly': readOnly,
        'allowBotMessages': allowBotMessages,
        'messagesPerHour': messagesPerHour,
        'postsPerHour': postsPerHour,
        'slowModeMs': slowModeMs
      };
}

final class SpaceRecord {
  final String id;
  final String title;
  final String ownerId;
  final bool publicChannel;
  final String defaultRoomId;
  final SpaceConfig config;
  final Set<String> adminIds;
  final int createdAtMs;
  SpaceRecord(
      {required this.id,
      required this.title,
      required this.ownerId,
      required this.publicChannel,
      required this.defaultRoomId,
      SpaceConfig? config,
      Set<String> adminIds = const {},
      required this.createdAtMs})
      : config = config ?? SpaceConfig(),
        adminIds = Set<String>.unmodifiable(adminIds);
  factory SpaceRecord.fromJson(JsonMap j) => SpaceRecord(
      id: j['id'] as String,
      title: j['title'] as String,
      ownerId: j['ownerId'] as String,
      publicChannel: j['publicChannel'] as bool,
      defaultRoomId: j['defaultRoomId'] as String,
      config: SpaceConfig.fromJson(_jsonMap(j['config'])),
      adminIds: _stringSet(j['adminIds']),
      createdAtMs: j['createdAtMs'] as int);
  SpaceRecord copyWith({SpaceConfig? config, Set<String>? adminIds}) =>
      SpaceRecord(
          id: id,
          title: title,
          ownerId: ownerId,
          publicChannel: publicChannel,
          defaultRoomId: defaultRoomId,
          config: config ?? this.config,
          adminIds: adminIds ?? this.adminIds,
          createdAtMs: createdAtMs);
  JsonMap toJson() => {
        'id': id,
        'title': title,
        'ownerId': ownerId,
        'publicChannel': publicChannel,
        'defaultRoomId': defaultRoomId,
        'config': config.toJson(),
        'adminIds': adminIds.toList()..sort(),
        'createdAtMs': createdAtMs
      };
}

final class MembershipRecord {
  final String spaceId;
  final String principalId;
  final String status;
  final int createdAtMs;
  const MembershipRecord(
      {required this.spaceId,
      required this.principalId,
      required this.status,
      required this.createdAtMs});
  factory MembershipRecord.fromJson(JsonMap j) => MembershipRecord(
      spaceId: j['spaceId'] as String,
      principalId: j['principalId'] as String,
      status: j['status'] as String,
      createdAtMs: j['createdAtMs'] as int);
  JsonMap toJson() => {
        'spaceId': spaceId,
        'principalId': principalId,
        'status': status,
        'createdAtMs': createdAtMs
      };
}

final class RoomRecord {
  final String id;
  final String spaceId;
  final String title;
  final String kind;
  final String? shadowConversationId;
  final RoomConfig config;
  RoomRecord(
      {required this.id,
      required this.spaceId,
      required this.title,
      required this.kind,
      this.shadowConversationId,
      RoomConfig? config})
      : config = config ?? RoomConfig();
  factory RoomRecord.fromJson(JsonMap j) => RoomRecord(
      id: j['id'] as String,
      spaceId: j['spaceId'] as String,
      title: j['title'] as String,
      kind: j['kind'] as String,
      shadowConversationId: j['shadowConversationId'] as String?,
      config: RoomConfig.fromJson(_jsonMap(j['config'])));
  RoomRecord copyWith({RoomConfig? config}) => RoomRecord(
      id: id,
      spaceId: spaceId,
      title: title,
      kind: kind,
      shadowConversationId: shadowConversationId,
      config: config ?? this.config);
  JsonMap toJson() => {
        'id': id,
        'spaceId': spaceId,
        'title': title,
        'kind': kind,
        'shadowConversationId': shadowConversationId,
        'config': config.toJson()
      };
}

final class ConversationRecord {
  final String id;
  final String kind;
  final String title;
  final String? spaceId;
  final String? roomId;
  final String? shadowOf;
  final String? postId;
  final List<String> participantIds;
  ConversationRecord(
      {required this.id,
      required this.kind,
      required this.title,
      this.spaceId,
      this.roomId,
      this.shadowOf,
      this.postId,
      List<String> participantIds = const []})
      : participantIds = List<String>.unmodifiable(participantIds);
  factory ConversationRecord.fromJson(JsonMap j) => ConversationRecord(
      id: j['id'] as String,
      kind: j['kind'] as String,
      title: j['title'] as String,
      spaceId: j['spaceId'] as String?,
      roomId: j['roomId'] as String?,
      shadowOf: j['shadowOf'] as String?,
      postId: j['postId'] as String?,
      participantIds: _strings(j['participantIds']));
  JsonMap toJson() => {
        'id': id,
        'kind': kind,
        'title': title,
        'spaceId': spaceId,
        'roomId': roomId,
        'shadowOf': shadowOf,
        'postId': postId,
        'participantIds': participantIds
      };
}

final class MessageRecord {
  final String id;
  final String conversationId;
  final String senderId;
  final List<JsonMap> parts;
  final int createdAtMs;
  MessageRecord(
      {required this.id,
      required this.conversationId,
      required this.senderId,
      required List<JsonMap> parts,
      required this.createdAtMs})
      : parts = _parts(parts);
  factory MessageRecord.fromJson(JsonMap j) => MessageRecord(
      id: j['id'] as String,
      conversationId: j['conversationId'] as String,
      senderId: j['senderId'] as String,
      parts: _parts(j['parts']),
      createdAtMs: j['createdAtMs'] as int);
  JsonMap toJson() => {
        'id': id,
        'conversationId': conversationId,
        'senderId': senderId,
        'parts': parts,
        'createdAtMs': createdAtMs
      };
}

final class ForumPostRecord {
  final String id;
  final String roomId;
  final String conversationId;
  final String authorId;
  final String title;
  final String messageId;
  final int createdAtMs;
  const ForumPostRecord(
      {required this.id,
      required this.roomId,
      required this.conversationId,
      required this.authorId,
      required this.title,
      required this.messageId,
      required this.createdAtMs});
  factory ForumPostRecord.fromJson(JsonMap j) => ForumPostRecord(
      id: j['id'] as String,
      roomId: j['roomId'] as String,
      conversationId: j['conversationId'] as String,
      authorId: j['authorId'] as String,
      title: j['title'] as String,
      messageId: j['messageId'] as String,
      createdAtMs: j['createdAtMs'] as int);
  JsonMap toJson() => {
        'id': id,
        'roomId': roomId,
        'conversationId': conversationId,
        'authorId': authorId,
        'title': title,
        'messageId': messageId,
        'createdAtMs': createdAtMs
      };
}

final class FeedPostRecord {
  final String id;
  final String authorId;
  final String visibility;
  final List<JsonMap> parts;
  final int createdAtMs;
  FeedPostRecord(
      {required this.id,
      required this.authorId,
      required this.visibility,
      required List<JsonMap> parts,
      required this.createdAtMs})
      : parts = _parts(parts);
  factory FeedPostRecord.fromJson(JsonMap j) => FeedPostRecord(
      id: j['id'] as String,
      authorId: j['authorId'] as String,
      visibility: j['visibility'] as String,
      parts: _parts(j['parts']),
      createdAtMs: j['createdAtMs'] as int);
  JsonMap toJson() => {
        'id': id,
        'authorId': authorId,
        'visibility': visibility,
        'parts': parts,
        'createdAtMs': createdAtMs
      };
}

final class FeedCommentRecord {
  final String id;
  final String postId;
  final String authorId;
  final List<JsonMap> parts;
  final int createdAtMs;
  FeedCommentRecord(
      {required this.id,
      required this.postId,
      required this.authorId,
      required List<JsonMap> parts,
      required this.createdAtMs})
      : parts = _parts(parts);
  factory FeedCommentRecord.fromJson(JsonMap j) => FeedCommentRecord(
      id: j['id'] as String,
      postId: j['postId'] as String,
      authorId: j['authorId'] as String,
      parts: _parts(j['parts']),
      createdAtMs: j['createdAtMs'] as int);
  JsonMap toJson() => {
        'id': id,
        'postId': postId,
        'authorId': authorId,
        'parts': parts,
        'createdAtMs': createdAtMs
      };
}

/// 已通过业务检查的原始变更事件。客户端存储可在外层签名/封装它。
final class DomainEvent {
  final String id;
  final String type;
  final String actorId;
  final int createdAtMs;
  final JsonMap data;
  DomainEvent(
      {required this.id,
      required this.type,
      required this.actorId,
      required this.createdAtMs,
      required JsonMap data})
      : data = _immutableMap(data);
  factory DomainEvent.fromJson(JsonMap j) => DomainEvent(
      id: j['id'] as String,
      type: j['type'] as String,
      actorId: j['actorId'] as String,
      createdAtMs: j['createdAtMs'] as int,
      data: _jsonMap(j['data']));
  JsonMap toJson() => {
        'id': id,
        'type': type,
        'actorId': actorId,
        'createdAtMs': createdAtMs,
        'data': data
      };
}
