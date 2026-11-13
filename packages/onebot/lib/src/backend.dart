import 'dart:async';

/// 已通过业务权限检查的 OneBot 投影错误；不包含凭据或内部异常文本。
class OneBotFailure implements Exception {
  const OneBotFailure(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'OneBotFailure($code)';
}

class BotProfile {
  const BotProfile(
      {required this.id,
      required this.name,
      this.displayName = '',
      this.remark = '',
      this.role = 'member'});
  final String id;
  final String name;
  final String displayName;
  final String remark;
  final String role;
}

class BotGroup {
  const BotGroup(
      {required this.id,
      required this.name,
      required this.memberCount,
      this.maxMemberCount = 0});
  final String id;
  final String name;
  final int memberCount;

  /// 0 表示业务未提供容量，不伪造一个平台限制。
  final int maxMemberCount;
}

class BotMessage {
  BotMessage(
      {required this.id,
      required this.conversationId,
      required this.sender,
      required this.parts,
      required this.createdAtMs,
      required this.detailType,
      this.groupId,
      this.peerId,
      this.guildId,
      this.channelId})
      : assert(detailType == 'private' || detailType == 'group');
  final String id;
  final String conversationId;
  final BotProfile sender;
  final List<Map<String, dynamic>> parts;
  final int createdAtMs;
  final String detailType;
  final String? groupId;
  final String? peerId;

  /// 非空表示同时具有 v12 guild/channel 标准投影；v11仍用groupId。
  final String? guildId;
  final String? channelId;
}

class BotChannel {
  const BotChannel(
      {required this.id, required this.name, required this.guildId});
  final String id;
  final String name;
  final String guildId;
}

/// 可选能力，只有具备无歧义两级映射的后端才声明支持。
abstract interface class OneBotChannelBackend {
  FutureOr<List<BotGroup>> getGuilds();
  FutureOr<BotGroup> getGuild(String guildId);
  FutureOr<List<BotChannel>> getChannels(String guildId);
  FutureOr<BotChannel> getChannel(String guildId, String channelId);
  FutureOr<BotMessage> sendChannel(
      {required String guildId,
      required String channelId,
      required List<Map<String, dynamic>> parts});
}

/// 原生论坛/朋友圈可选能力，仅通过 zaizuo. 扩展动作暴露，不冒充标准动作。
/// 返回扩展JSON：原生字符串ID、完整message数组、time为UTC Unix浮点秒。
/// 所有读写/评论/点赞必须以同一固定bot独立执行权限检查。
abstract interface class OneBotSocialBackend {
  FutureOr<Map<String, dynamic>> postForum(
      {required String roomId,
      required String title,
      required List<Map<String, dynamic>> parts,
      String? idempotencyKey});
  FutureOr<Map<String, dynamic>> replyForum(
      {required String postId,
      required List<Map<String, dynamic>> parts,
      String? idempotencyKey});
  FutureOr<List<Map<String, dynamic>>> getPosts(
      {required String roomId, int limit = 50, String? beforeId});
  FutureOr<Map<String, dynamic>> postFeed(
      {required List<Map<String, dynamic>> parts,
      String visibility = 'friends',
      String? idempotencyKey});
  FutureOr<List<Map<String, dynamic>>> getFeed(
      {String? authorId, String? postId, int limit = 50, String? beforeId});
  FutureOr<Map<String, dynamic>> commentFeed(
      {required String postId,
      required List<Map<String, dynamic>> parts,
      String? idempotencyKey});
  FutureOr<Map<String, dynamic>> likeFeed(
      {required String postId, bool liked = true, String? idempotencyKey});
}

/// 附件可选能力。file_id由可信宿主按固定bot签发，不是URL、path或自报scope。
/// 上传暂存并不等于发送；send必须在目标已确定后另做文件与会话授权。
abstract interface class OneBotMediaBackend {
  bool get mediaEnabled;
  int get maxMediaBytes;
  FutureOr<Map<String, dynamic>> uploadFile(
      {required String name,
      required List<int> bytes,
      required String mime,
      required String purpose});
  FutureOr<Map<String, dynamic>> getFile(String fileId);
}

/// 每个实例固定绑定一个已授权 bot。实现者必须在所有查询和事件上检查读权限。
/// 只有应用启动配置可以构造实例；请求中的 self 绝不能选择另一个实例。
abstract interface class OneBotBackend {
  String get botId;
  Stream<BotMessage> get messages;
  FutureOr<BotProfile> getSelf();
  FutureOr<BotProfile> getUser(String userId);
  FutureOr<List<BotProfile>> getFriends();
  FutureOr<List<BotGroup>> getGroups();
  FutureOr<BotGroup> getGroup(String groupId);
  FutureOr<List<BotProfile>> getGroupMembers(String groupId);
  FutureOr<BotMessage> getMessage(String messageId);
  FutureOr<BotMessage> send(
      {required String detailType,
      required String targetId,
      required List<Map<String, dynamic>> parts});

  /// 返回值仅表示业务内核当前可用，不声称已有外网连接或消息送达。
  FutureOr<bool> isOnline();
}
