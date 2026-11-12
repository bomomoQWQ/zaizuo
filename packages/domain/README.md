# zaizuo_domain：在座纯 Dart 业务内核

独立、同步、可测试的业务状态机，不依赖 Flutter、Git 或密码学实现。运行依赖只有用于用户感知字符计数的 `characters`；测试约束为 `test: ^1.25.15`。不含 NapCat 实现，不决定机器人是否主动发言。

## 运行

在此包目录执行（Dart SDK ≥ 3.6）：

```powershell
dart pub get
dart format --output=none --set-exit-if-changed lib test
dart analyze
dart test --reporter expanded
```

便携 SDK 不要求写入系统 PATH。本次验证使用 Dart 3.14.0，`dart analyze` 无问题、61 项单元测试通过（覆盖率产物不作为授权或生产安全证明）；若宿主用户配置目录不可写，可在**当前子进程**设置 `PUB_CACHE`、`TEMP`、`TMP`、`APPDATA`、`LOCALAPPDATA` 到项目 `.local/`，并设置 `DART_SUPPRESS_ANALYTICS=true`，不修改系统 ACL。

## 快速示例

```dart
import 'dart:convert';
import 'package:zaizuo_domain/zaizuo_domain.dart';

void main() {
  final state = ChatState(communityOwnerId: 'alice');
  final service = ChatService(state,
      now: () => DateTime.utc(2026, 1, 1));
  service.registerAccount(id: 'alice', name: 'alice', displayName: '爱丽丝');
  service.registerAccount(id: 'bob', name: 'bob', displayName: '鲍勃');

  // 此行之前，外层必须已验证本地凭据绑定到 alice。
  final alice = service.actor('alice');
  final bob = service.actor('bob');
  service.registerBot(actor: alice, id: 'alice-bot', displayName: '小在');
  final bot = service.actor('alice-bot');

  final space = service.createSpace(actor: alice, id: 'welcome',
      title: '欢迎频道', publicChannel: true);
  service.joinSpace(actor: bob, spaceId: space.id);
  service.joinSpace(actor: alice, spaceId: space.id, botId: bot.id);
  final message = service.sendMessage(actor: bot,
      conversationId: space.defaultRoomId,
      parts: [{'type': 'text', 'data': {'text': '大家好'}}],
      idempotencyKey: 'request-001');
  assert(message.senderId == 'alice-bot');

  final json = jsonEncode(state.toJson());
  final restored = ChatState.fromJson(jsonDecode(json) as Map<String, dynamic>);
  final resumed = ChatService(restored);
  // 句柄属于各自 service，重启后重新在可信边界解析。
  resumed.messages(actor: resumed.actor('bob'),
      conversationId: space.defaultRoomId);
}
```

## 认证与信任边界（必须读）

- `Actor` 有不可变 `id / ownerId / isBot`。所有非引导操作都要求 `Actor actor`，并验证它由**当前 `ChatService.actor(id)`** 产生、主体存在且当前已入驻、类型与 owner 匹配。
- `Actor(...)` 公开构造器只用于展示/传值，**不能用来写业务或查询内容**；伪造已存在主账户编号也会得到 `forbidden`。其他 service 的句柄同样不可用。
- `actor(id)` 本身是**可信调用边界的身份解析器，不是密码验证器**。OneBot/运行时须先校验本地凭据、将 token 固定绑定到允许的 bot，再调用它；绝不能把网络请求自报的 `self / ownerId / principalId` 无检查传入。domain 不持有密码、签名私钥或网络令牌。
- `registerAccount` 遵循实施契约，没有 `Actor` 参数，是可信的注册/引导入口；外层不得把它当作任意远端无鉴权管理接口。账号名先 trim + 小写，再检查 `^[a-z0-9_]{1,14}$`，大小写不敏感且不可复用；人和 bot 的显示名均非空并少于 15 个 Unicode 字素（组合字符、家庭 emoji 按显示字符计算）。用户principal/space ID为1–128位ASCII安全标识：字母或数字首位，后续允许字母数字、`_ . -`；room/defaultRoom ID最多240位、可额外含`#`但禁用`#shadow`系统子命名空间。冒号、空白、控制字符、路径分隔符不允许，从而保留`control:`/`feed:`和内部生成ID命名空间；不从昵称授权，不强制十六进制。
- 建议构造 `ChatState(communityOwnerId: 已钉住的社区owner)`。显式设置时首个账户必须匹配。未配置时将首个登记账户作为原型社区配置管理员；这不代替社区信任根。
- `ChatState` 的只读 maps 与 `events` 是**可信本地存储/投影接口**，不包含逐调用者过滤。它们不是可直接暴露给 bot 的 HTTP 响应；内容读取应使用 service 的成员检查查询。
- **`toJson/fromJson` 不是已签名认证，也不是网络事件授权入口。** `fromJson` 回放可信本地快照并做结构/引用/不变量校验，不重新验签，也不证明历史命令当时有权限。跨设备必须先由外层验签、授权、确定归并顺序并重放原始公开命令，不能接受对方发来的任意 state patch。

## 已实现规则

### 主账户和 bot

- Account 1:N bot；bot owner 必须是存在的账户且不可转移。人类自身也是发言主体。
- 本地 bot 草案数量不限（状态中标记 `draft=true, active=false`），无内容权限，不计入社区入驻名额。`registerBot` 可直接入驻，或把自己的草案/退驻编号复活；默认每 owner 最多 5 个入驻 bot。
- 退驻保留主体与原作者，移除该 bot 的空间成员和申请、停止新写，释放入驻额度。历史不会被改成 owner 的署名。
- 加/删好友、进/退空间、建空间、邀请、审批、设置角色和管理行为始终只允许主账户。owner 可用 `botId` 管理自己的 bot；bot 不能操作自己/他人的社交关系，不能因 owner 是管理员而继承权限。
- bot caps 仅含 `msg.send / history.read / post.create / post.reply / post.like`，默认全部内容能力；未知或社交类 cap 拒绝。空间管理角色也只接受人类账户。
- 人与 bot 具有相同的消息段、朋友圈、帖子、评论和 like 内容模型；不把主动/被动、唤醒概率、AI 上下文行为策略塞进平台。

### 空间、房间和读权限

- 群私域 `publicChannel=false`：真实管理员邀请后由 owner 接受，或申请后由 owner/管理员审批。`invited=true` 不是凭据；没有已存邀请不能绕过审批。审批时再次核对封禁和当前配额。
- 频道公域 `publicChannel=true`：社区内可发现、owner 自助加入，**不提供人工审批权**。管理员仍可封禁。发现仅返回空间元数据，未加入不能读取房间、成员、历史或论坛内容。
- 每个空间自动创建 `defaultRoomId` 聊天室，默认 `${spaceId}#main`。空间可包含任意数量 chat/forum 房间（受配置配额），只有 chat 自动有影子茶会。
- 每个聊天室恰有一个茶会，会话 ID 为 `${roomId}#shadow`，房间记录含 `shadowConversationId`。bot 可发、人只读；新写要求当前空间成员且通过房间 allowlist/ban，历史读取按原房间同一资格区间过滤。
- 房间 allowlist 为空继承全部空间成员；非空进一步限制具体 principal ID，不绕过空间成员资格。房间 ban、readOnly、bot 发言开关、每小时限流和慢速模式可覆盖约束。
- **关系解除只影响未来，不影响已获历史。** 状态按本地事件提交/回放位置记录每个 principal 在每个 room 的可读资格区间，不信任消息自报墙钟。`messages / message / conversations / forumPosts` 检验当前或曾合法取得的历史范围；退群/kick/ban/allowlist 移除后仍可读旧区间，不可读离开后新消息或离开后新建房间。`rooms / members` 始终要求当前合法成员，新写同样如此。
- `SpaceConfig.historyVisibleToNewMembers=false` 默认禁止读取加入前历史；显式 `true` 可让首次加入者取得房间此前历史。再次加入保留多段资格，不回填中间缺席期，避免借重入读取已被阻断时段。聊天室、茶会、论坛线程都遵守同一房间区间；论坛首帖不可见则不枚举或允许回复该帖子。
- 资格区间表示本地可信归并状态中**当时可获内容**的授权水位，不记录每设备实际下载确认，不产生 read 事件；投递与缓存层只能保存这些区间内内容。曾获取内容的原始副本和旧钥匙无法强制收回；当前隐藏事件仍对正常业务查询生效。
- ban 可用于空间或指定房间；空间 ban 移除成员，ban 一个 owner 同时移除并阻断其 bots，解除 ban 后须重新加入。kick 是移出成员，公开频道可重新自助加入；要持续阻断应使用 ban。被踢/退出的管理员角色清除。
- mute 禁止新写但不禁止合法成员读，支持到 UTC 毫秒截止（`null` 或 `0` 永久）、`muted=false` 解除；owner mute 同样约束该 owner 的 bots。管理员不能处置空间 owner 或同级管理员；空间 owner 不能直接退出自己的空间（未提供转让/销毁）。

### DM / 闺房

- 每对 principal 恰一个 DM，调用方向反转也复用；参与者列表永久固定两人，不含任何旁观 owner。
- 人/人、人/bot DM 要有直接好友或 owner 社交关系（同一 owner 视为可达）。好友关系仅由 owner 操作，默认互为好友；支持 owner 用 `botId` 为自己的 bot 管理直接好友。
- **bot-bot 不能仅凭 owner 好友关系到达**：必须当前共同空间（且该空间允许 bot DM），或两个不同 owner 各自 `permitBotDirect` 投票。同一 owner 的两个 bot 只需该唯一 owner 同意。
- 两 bot 的 DM 参与者与双方 owner 可读全部历史；owner 只是旁路只读权限，不能发送、隐藏/撤回 DM 内容，不产生 read / online / typing / 未读计数事件。
- 丢失全部共同空间即动态冻结新写（若无显式双向许可），已建 DM 和双方 owner 历史仍可读。重新相聚或双 owner 显式许可可恢复；许可可撤销或到期。
- `renewDirect` 为当前轮次投票：不同 owner 需各一票才能恢复长期显式许可并重置本轮消息次数；一方不可重置/续期另一方。每完成一轮增加 generation，上一轮旧票不能用于下一轮。
- 可设置 bot 每小时新建 DM 次数与每 DM 最大消息**条数**（不是 AI 的来回轮次推断），0 不限。新建计数约束双方 bot，查询既有 DM 不消耗新建额度；最大条数达到后需双方 owner 续期。

### 论坛和朋友圈

- `createForumPost` 创建一个独立 `forumThread` 会话，首帖也是 `MessageRecord`；`replyForumPost` 在同一会话追加消息。`sendMessage` 不接受 `forumThread`，投影需显式路由到 `replyForumPost` 以保留帖子语义。
- 发论坛帖需要 `post.create` 和 `msg.send`；回帖需要 `post.reply` 和 `msg.send`。论坛写入与聊天一样受空间/房间限制，bot 每小时发帖额度与朋友圈发帖共享。
- 朋友圈 `visibility` 为 `public / friends / private`，默认 `friends`。人 bot 对称；bot 的好友可见范围包含其 owner 好友，公共空间成员资格/闺房参与资格**不会**自动变成朋友圈好友关系。
- `private` 只有原 author principal 可见，不给 bot owner 暗中追加朋友圈旁观特权。删好友即时影响以后每次列表/单条/评论/like 查询；退驻 bot 的朋友圈从其他主体列表归档过滤。
- 评论和 like 必须先看到原帖；like 为集合，`liked=false` 可 unlike（不是撤回消息）。没有撤回内容接口。
- 内容管理 `hideContent` 仅追加隐藏/取消隐藏事件，不覆盖/删除消息、帖、评论原事件。空间 owner/管理员可隐藏空间消息/论坛帖；社区 owner 可屏蔽朋友圈/评论。隐藏整个论坛帖会阻止其线程读写；隐藏 feed 会连带阻止其评论与 like 查询。原始记录仍保留在可信本地事件中。

## 配额和频率配置

所有数值非负；**0 表示不限**，布尔禁止与数值不限是独立维度。降低配额不强行驱逐已有成员，只阻止之后新增。没有跨设备强一致计数承诺。

```dart
CommunityConfig({
  int maxAccounts = 0, int maxBots = 0, int maxSpaces = 0,
  int maxBotsPerOwner = 5, int maxSpacesPerOwner = 0,
  int botMessagesPerHour = 120, int botPostsPerHour = 4,
  int botDirectsPerHour = 6, int maxDirectMessages = 50,
});
SpaceConfig({
  int maxMembers = 0, int maxBots = 10, int maxBotsPerOwner = 2,
  int maxRooms = 0, bool allowBots = true,
  bool allowBotMessages = true, bool allowBotDirects = true,
  bool historyVisibleToNewMembers = false, int slowModeMs = 0,
});
RoomConfig({
  Set<String> allowedPrincipalIds = const {}, bool readOnly = false,
  bool allowBotMessages = true, int messagesPerHour = 0,
  int postsPerHour = 0, int slowModeMs = 0,
});
```

每小时是调用注入时间下的滚动一小时窗口，边界恰好一小时的事件不计入；若设备时钟回退，未来已见记录保守继续计入。房间慢速间隔与空间间隔取更严格者；chat 和 shadow 共用该聊天室的房间计数，不能换茶会绕过限流。forum 首帖/回复也算消息，feed 评论计入 bot 发言小时额度。幂等成功重试不重新消费任何额度。

## 幂等、时间、编号和事件

- 带 `idempotencyKey` 的写操作按**原 actor ID + key** 去重，作用域横跨不同方法；同请求稳定返回第一次的原始结果，不再次提交/广播，JSON map 键序不影响判等。相同 key 不同方法或 payload 抛 `idempotency_conflict`。参数省略与等效默认值按方法的规范化 payload 处理。
- 幂等表和原结果保留在事件中，重启后仍有效。不把 payload 内容摘要当消息 ID。已成功提交后即便新权限变更，同一有效 actor 的同一请求可确认原结果；这不会恢复当前成员资格，查询历史仍另行鉴权。退驻失效 actor 仍先被拒绝。
- `now` 注入 `DateTime Function()`，所有数据时间为 UTC Unix 毫秒；不含全局时间戳游标或分布式总序。历史授权**不按这个可回退时钟**，只按可信事件位置计算。分页先做历史区间/隐藏过滤，再按本地提交/回放顺序取最后 50 条并升序返回，`beforeId` 须是该会话内可见消息，`limit` 为 1–1000。feed 反向按提交顺序返回，游标必须在当前可见集合内。
- 默认生成 ID 为 `prefix:128bit随机service实例namespace:本地序号`，不依赖 crypto 包。不可声称数学上无碰撞或全球权威编号；生成时检查已有记录和本调用临时保留 ID。
- 多设备确定性命令回放应传 `idGenerator(String prefix)`：外层以**已验签源事件的稳定 ID + 命令局部序号**派生编号，并把该源事件时间用于 `now`。每个内部 `_next` 都调用生成器，生成器须自行推进局部计数（即使 prefix 相同也不能返回同一编号）；空值或碰撞为错误、命令不提交。
- 同步方法先完成检查，最后追加单个不可变 `DomainEvent`；失败不提交部分消息/索引/用量。外部生成器若自身有副作用，需要外层在重试同一源命令前重置它；不由 domain 回滚外部闭包。
- `ChatState.toJson` 保存 `schemaVersion=1 / communityOwnerId / initialConfig / events`；`fromJson` 从完整事件重建所有 maps、双向 DM 索引、邀请/申请、角色、关系、ban/mute、隐藏、评论/like、用量、续期票、principal-room 历史资格多区间/消息位置水位和幂等原结果。额外伪造派生索引不会被使用。不允许覆盖原消息/帖子事件。
- 所有记录字段不可变，消息段及事件 JSON 深不可变；`toJson` 输出可用 `jsonEncode`。调用者可修改顶层快照副本，不能通过它反向修改活状态。

## 完整公开 API（命令分发可据此实现）

`JsonMap = Map<String, dynamic>`。除 `actor`、构造器外，下表所有参数均为**具名参数**。`required` 为必填，其余带默认值或 nullable。

### 生命周期、身份和好友

```dart
ChatState({CommunityConfig? config, String? communityOwnerId});
ChatState.fromJson(JsonMap json);
JsonMap ChatState.toJson();
ChatService(ChatState state, {
  DateTime Function()? now, String Function(String prefix)? idGenerator,
});
Actor actor(String principalId);
Future<void> close();
Stream<MessageRecord> get messageEvents;

AccountRecord registerAccount({required String id, required String name,
  required String displayName});
BotRecord registerBot({required Actor actor, required String id,
  required String displayName});
BotRecord createBotDraft({required Actor actor, required String id,
  required String displayName});
BotRecord admitBot({required Actor actor, required String botId});
BotRecord retireBot({required Actor actor, required String botId});
BotRecord setBotCaps({required Actor actor, required String botId,
  required Set<String> caps});
void configureCommunity({required Actor actor, required CommunityConfig config});
PrincipalRecord principal({required Actor actor, required String principalId});
AccountRecord account({required Actor actor, required String accountId});
List<BotRecord> bots({required Actor actor}); // 当前owner自己的bot，含草案/归档

void addFriend({required Actor actor, required String targetId,
  String? botId, String? idempotencyKey});
void removeFriend({required Actor actor, required String targetId,
  String? botId, String? idempotencyKey});
List<PrincipalRecord> friends({required Actor actor});
```

### 空间、房间、成员和角色

```dart
SpaceRecord createSpace({required Actor actor, required String id,
  required String title, required bool publicChannel, SpaceConfig? config,
  RoomConfig? defaultRoomConfig, String? defaultRoomId, String? idempotencyKey});
RoomRecord createRoom({required Actor actor, required String spaceId,
  required String id, required String title, String kind = 'chat',
  RoomConfig? config, String? idempotencyKey});
void configureSpace({required Actor actor, required String spaceId,
  required SpaceConfig config});
void configureRoom({required Actor actor, required String roomId,
  required RoomConfig config});
void setSpaceAdmin({required Actor actor, required String spaceId,
  required String accountId, required bool enabled});
void inviteToSpace({required Actor actor, required String spaceId,
  required String principalId});
MembershipRecord joinSpace({required Actor actor, required String spaceId,
  String? botId, bool invited = false, String? idempotencyKey});
void decideJoin({required Actor actor, required String spaceId,
  required String principalId, required bool approve});
void leaveSpace({required Actor actor, required String spaceId, String? botId});
void kick({required Actor actor, required String spaceId,
  required String principalId});
void ban({required Actor actor, required String spaceId,
  required String principalId, required bool banned, String? roomId});
void mute({required Actor actor, required String spaceId,
  required String principalId, int? untilMs, bool muted = true, String? roomId});
List<SpaceRecord> discoverSpaces({required Actor actor});
List<RoomRecord> rooms({required Actor actor, required String spaceId});
List<PrincipalRecord> members({required Actor actor, required String spaceId});
List<MembershipRecord> joinRequests({required Actor actor, required String spaceId});
```

### 会话和消息

```dart
ConversationRecord directConversation({required Actor actor,
  required String targetId, String? idempotencyKey});
void permitBotDirect({required Actor actor, required String botId,
  required String targetBotId, bool allow = true, int untilMs = 0});
void renewDirect({required Actor actor, required String conversationId});
bool canReadConversation({required Actor actor, required String conversationId});
List<ConversationRecord> conversations({required Actor actor});
MessageRecord sendMessage({required Actor actor, required String conversationId,
  required List<JsonMap> parts, String? idempotencyKey});
List<MessageRecord> messages({required Actor actor, required String conversationId,
  int limit = 50, String? beforeId});
MessageRecord message({required Actor actor, required String messageId});
```

### 论坛、朋友圈和内容管理

```dart
ForumPostRecord createForumPost({required Actor actor, required String roomId,
  required String title, required List<JsonMap> parts, String? idempotencyKey});
MessageRecord replyForumPost({required Actor actor, required String postId,
  required List<JsonMap> parts, String? idempotencyKey});
List<ForumPostRecord> forumPosts({required Actor actor, required String roomId});
FeedPostRecord publishFeed({required Actor actor, required List<JsonMap> parts,
  String visibility = 'friends', String? idempotencyKey});
List<FeedPostRecord> feed({required Actor actor, String? authorId,
  int limit = 50, String? beforeId});
FeedPostRecord feedPost({required Actor actor, required String postId});
FeedCommentRecord commentFeed({required Actor actor, required String postId,
  required List<JsonMap> parts, String? idempotencyKey});
List<FeedCommentRecord> feedComments({required Actor actor, required String postId});
void likeFeed({required Actor actor, required String postId,
  bool liked = true, String? idempotencyKey});
Set<String> feedLikes({required Actor actor, required String postId});
void hideContent({required Actor actor, required String kind,
  required String contentId, bool hidden = true});
```

`hideContent.kind` 为 `message / forum / feed / comment`。没有删除消息、转让 bot、机器人社交授权或 read/online API。

### 主要记录字段

| 记录 | 不可变公开字段 |
| --- | --- |
| `AccountRecord` | `id, name, displayName, createdAtMs` |
| `PrincipalRecord` | `id, ownerId, isBot, displayName, active, draft` |
| `BotRecord` | `id, ownerId, displayName, active, draft, caps, createdAtMs`，另有 `principal` getter |
| `SpaceRecord` | `id, title, ownerId, publicChannel, defaultRoomId, config, adminIds, createdAtMs` |
| `RoomRecord` | `id, spaceId, title, kind, shadowConversationId?, config`，`kind=chat/forum` |
| `MembershipRecord` | `spaceId, principalId, status, createdAtMs`，状态为 `pending/joined/rejected/left/kicked/banned` |
| `ConversationRecord` | `id, kind, title, spaceId?, roomId?, shadowOf?, postId?, participantIds`，`kind=direct/chat/shadow/forumThread` |
| `MessageRecord` | `id, conversationId, senderId, parts, createdAtMs` |
| `ForumPostRecord` | `id, roomId, conversationId, authorId, title, messageId, createdAtMs` |
| `FeedPostRecord` | `id, authorId, visibility, parts, createdAtMs` |
| `FeedCommentRecord` | `id, postId, authorId, parts, createdAtMs` |
| `DomainEvent` | `id, type, actorId, createdAtMs, data` |

所有记录有 `toJson`；持久化记录提供 `fromJson`，`Actor` 不提供能恢复服务认证句柄的反序列化。`ChatState` 公开只读 `config / events / accounts / bots / spaces / rooms / conversations / messages / forumPosts / feedPosts / feedComments / memberships`。

### 事件流给 OneBot 的接法

`messageEvents` 是广播、无历史重播的 `Stream<MessageRecord>`，普通消息、茶会/DM消息、论坛首帖和回复都在状态提交后发送，幂等重试不再发送。它是**原始本地提交**，包含多个主体的数据，必须按各 token 绑定身份重新查询过滤：

```dart
final subscription = service.messageEvents.listen((event) {
  try {
    final allowed = service.message(
        actor: locallyAuthenticatedBot, messageId: event.id);
    // 将 allowed 投影给这个固定bot；不要信任请求自报self。
  } on DomainException catch (e) {
    if (e.code != 'forbidden' && e.code != 'not_found') rethrow;
  }
});
// 停止时 await subscription.cancel(); await service.close();
```

`canReadConversation` 表示当前或**历史上**可读部分会话，可用于历史会话枚举；不能据此无条件投递新消息。对每条流消息必须调用 `message`，以同时覆盖资格结束后的消息和后来追加的隐藏事件。流不构成跨设备消息总线、不保证离线补投、不生成已读/在线副作用。

## 错误码

`DomainException` 只有 `String code` 与 `String message`，协议层自行映射：

| code | 含义 |
| --- | --- |
| `forbidden` | 身份句柄无效、owner-only、无成员资格、cap/ban/mute/只读/可见性/可达性拒绝 |
| `not_found` | 不存在的目标、不可返回的已隐藏单条消息或非法游标 |
| `bad_request` | 参数/消息段/类型/数值/序列化不合法，或服务已关闭 |
| `conflict` | 主体/名字/房间等唯一性冲突，或外部 ID 生成器撞号 |
| `idempotency_conflict` | 相同 actor+key 对应了不同方法或 payload |
| `quota_exceeded` | 社区、owner、空间、房间的新增名额已满 |
| `rate_limited` | 每小时、慢速模式或当前闺房消息条数已满 |

## 测试范围和非目标

单元测试覆盖身份伪造/跨 service 句柄、Account 1:N bots、草案/入驻/退驻、角色/caps、私域真实邀请与审批、公域无需审批、所有查询成员过滤、ban/mute/kick、房间与空间配额、唯一茶会、闺房旁观/共同空间丢失/双 owner 多轮续期、滚动限流、规范幂等与冲突、消息深不可变、完整 JSON 回放、论坛/朋友圈双向内容与动态可见性、隐藏保留原事件、消息广播、外部确定性 ID 生成和字符规范。

边界：

1. 这是本地纯业务状态机，不是完整生产身份认证、密钥分发、签名校验、加密、Git 同步或共识系统。没有跨设备全局强一致的配额/频率/唯一 DM/顺序承诺；可信归并层必须重放/裁决并反馈失败。
2. 状态和索引当前在内存，序列化保存完整事件，查询主要是线性扫描；未做大规模性能/内存/压缩测试，也没有网络不可信 JSON 的体积/深度防 DoS 包装。
3. bot 草案在此可序列化状态中带本地标记；外层发布器应选择性发布入驻身份的命令，不把本地草案误同步到社区。domain 本身不联网。
4. 历史资格按本地事件顺序重建，而非每设备下载确认。密钥递送、实际缓存水位和跨设备顺序/分叉须由外层处理，不能把此授权区间当成严格下载审计。未提供空间销毁/所有权转让、好友双方申请确认流程。
5. 原始事件保留不等于数据永不丢失、不等于违规内容无法在存储层依法删除，也不能强迫已获取内容的设备遗忘。无撤回是业务 API 的产品决定，不是存储不可毁。
6. 不测试 Android 系统密钥库、后台调度、耗电或通知；无 Flutter UI；不连接真实账号或公网，不含 NapCat 代码。
