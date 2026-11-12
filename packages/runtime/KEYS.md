# 会话密钥分发授权（ConversationKeyManager）

这是 runtime 对 domain 当前授权与 core recipient 封装的协调层。只读业务状态，不创建成员资格、不进行人工频道审批、不改变机器人发言权限；无私钥/明文会话key写入Git的API。核心接口和序列化模型位于本目录源码，供父运行时的 `key.rotate / key.grant` 控制通道事件接入。

## 已验证范围

Dart 3.14.0 下格式化、静态分析、20项专项测试通过。覆盖频道任意成员分发、私域pending拒绝、新成员强制新epoch、退出/ban/重入、room/shadow/forum、bot owner映射、闺房owner只读收key、feed可见性、cap撤销、epoch冲突锁止、签名冒充/篡改/社区/recipient/承诺核对、metadata恢复和发送前当期key验证。

此处的密码学测试是原型回归，不是独立安全审计。外层设备授权、可信公钥目录、事件排序/完整性、会话内容加密通道与私钥安全存放仍须独立验证。

## 公开 API

```dart
ConversationKeyManager({
  required ChatService service,
  required String communityId,
  required Map<String, IdentityPublic> trustedAccounts,
  Set<String>? communityAccountIds,
});
KeyAudience resolveAuthorizedRecipients(String conversationId);
KeyEpochAnnouncement? currentAnnouncement(String conversationId);
Set<String> get conflictedConversations;
Set<String> get communityAccountIds;
void setCommunityAccounts(Set<String> ids);

Future<KeyRotation> generate({
  required Identity sender, required String conversationId,
});
Future<void> authorizeAnnouncement({
  required KeyEpochAnnouncement announcement,
});
Future<void> validateCurrentKey({required ConversationKey key});
Future<KeyGrant> issue({
  required Identity sender,
  required ConversationKey key,
  required KeyEpochAnnouncement announcement,
  required String recipientPrincipalId,
});
Future<ConversationKey> receive({
  required Identity recipient, required KeyGrant grant,
});
Map<String, dynamic> toJson();
static Future<ConversationKeyManager> fromJson(
  Map<String, dynamic> json, {
  required ChatService service,
  required String communityId,
  required Map<String, IdentityPublic> trustedAccounts,
  Set<String>? communityAccountIds,
});
```

`KeyAudience`：

- `String conversationId`
- `Map<String,String> principalOwnerIds`：授权 principal → 实际recipient账号映射，深只读。
- `Set<String> accountIds`：上面 values 去重；每个账号可代其被授权bot收取recipient封装。
- `List<String> authorizationEventIds`：相关域授权事件的稳定提交/回放水位；列表只读。
- `String policyToken`：上述两个授权维度的规范JSON，不含秘密。
- `toJson()`：`conversation / principals / authorization_events`。

`KeyRotation`：只提供 `.key`（`ConversationKey`，秘密，只留本地）与 `.announcement`（无秘密的签名公告）。不提供能把原key悄悄序列化发布的 `toJson`。

`KeyEpochAnnouncement`、`KeyGrant` 均提供 `fromJson(Map<String,dynamic>) / toJson()`，签名body与嵌套JSON深不可变。公告公开 `communityId / conversationId / epoch / issuerAccountId / keyCommitment / principalOwnerIds`；grant公开 `conversationId / epoch / recipientPrincipalId / recipientAccountId / senderAccountId / announcement`。

## 主体与账户不能混淆

- domain 的 principal（人或bot）是可读/可写资格单位；core 的 `IdentityPublic` 是账号级签名/交换公钥。bot没有在此模块伪造独立主账户密钥，接收映射为 `botId → bot.ownerId`。
- `trustedAccounts` 必须由外层已钉住、已验证的账户目录构建，索引必须等于 `IdentityPublic.accountId`；来自信封的sender ID只用于**查这个目录**，不接受自报公钥。
- `communityAccountIds` 是外层**已验签历史manifest revision**的当前成员子集，不从信封自报名单取值；省略时兼容本地测试默认state全部账户。`setCommunityAccounts(ids)`在同一manager上更新可信上下文、保留epochs/冲突，校验ids均为state存在且已钉住账户。所有principal的owner与issuer/recipient账户均受此子集限制；public feed只包含这批账户及其bot。重放旧revision时先设置旧名册，不能把latest新增账户追溯加入旧public audience。
- private feed的策略只跟作者owner/作者bot有关，不受无关账号新增或无关好友事件污染；friends跟实际作者/owner社交关系有关；public新增合法账户仍要求新epoch。member manifest历史、稳定bootstrap事件ID和按事件revision切换由外层负责；调用者任意设置上下文不能被当成网络授权证明。
- 传入 `Identity` 必须与已钉住公钥全部一致；相同账号名/ID但新生成一套公钥不能绕过验证。
- 空间里只有bot加入、owner未加入时，owner账号可代表其bot封装/接收key；audience中不凭空增加owner principal，domain仍拒绝该人类直接读空间/发言/代bot社交。
- bot的 `private` feed 只列bot principal，不额外把owner作为可见作者主体；**现实上bot使用owner账户的密钥**，因此此原型不宣称能在密码学上把owner与其bot本人隔离。进一步隔离需要独立bot设备/密钥设计。

## 当前接收范围

### room / chat / shadow / forum

- 空间只接受当前 `joined`、未退驻/草案、具有 `history.read` 的principal，再通过当前 `service.rooms` 的空间ban/房间ban/allowlist检查。
- 房间ID（含forum房间）、chat会话、shadow会话和forumThread都支持；forumThread还要求当期principal确实能读首帖且帖未隐藏。runtime可按当前协议以forum房间ID加密，帖子独立会话业务语义不改变。
- 茶会人与bot都有读资格，但人仍只读。分发key不是授予写能力。
- 不用 `canReadConversation=true` 单独决定新epoch：离开者可能仍能看旧历史，但不是当前成员，不能领未来key。
- 公开频道加入已是合法domain自助事件后，**任意当期成员**可自动向新成员分发新期次，不要求社区/空间owner在线，也不叫人工审批。没有成员在线仍可能等候，不能声称密钥即时送达。

### direct / bot-bot 闺房

- 一般DM只给两位participant principal；如果participant是bot，则recipient账户映射到其owner。
- bot-bot DM另外显式授权两边owner principal收key，让owner真正能解密旁观全部历史，不只是UI可见。owner没有加入participantIds；domain仍拒绝owner发言，不生成read/online/typing事件。
- 共同空间消失冻结的是写可达性，DM永久participant与合法owner的历史只读资格不因此撤销。当前DM key仍可按此永久读范围分发；未来消息是否可发继续由domain动态判定。
- 无关人、其他bot或未知secret范围不能领DM key。

### feed scope

只识别 `feed:<authorPrincipalId>:<public|friends|private>`，用最后一个冒号分离visibility，其他未知scope不默认降级全社区。`control:`明确不属于本manager；`feed:`/`control:`若与已有业务room/conversation碰撞立即`forbidden`，不先按房间解释。domain用户给定ID不允许冒号、控制字符、路径分隔符，也不得占用`#shadow`子命名空间，从创建和快照重建两端阻止内部scope混淆。

- public：社区所有当前合法且有history.read的principal → owner账户去重。
- friends：作者本人 + `domain.friends(actor:author)`，包含owner好友派生关系，人bot对称。
- private：仅作者principal → 其账户（bot映射到owner，但不增加owner主体权限）。
- 草案、退驻bot过滤；删好友、入驻/退驻/账号变更会使策略水位变化，强制新epoch。此模块不提供feed内容发布/评论/like权限，仍由domain裁定。

## epoch 与历史隔离

1. `generate` 用core `ConversationKey.generate`为每个期次独立随机生成32字节，绝不从旧key派生，也不只用旧key包新key。
2. `SpaceConfig.historyVisibleToNewMembers` 默认false。加入后不能把此前同一旧key发给新人再仅靠业务查询过滤；当前audience和授权事件水位必须匹配公告，成员/ban/room授权变动后旧公告为 `stale_key`，应先生成新epoch。
3. 授权水位含相关稳定domain事件ID，不仅是当前集合：退出后重入即使集合恢复一样，旧epoch也不能重发为当前。普通聊天消息不影响策略水位；只读无关的mute不影响key读资格。本地草案事件不发布，策略忽略draft变化。
4. 公告含 `key_commitment`（绑定community/conversation/epoch/key）和 `key_fingerprint`（绑定community/conversation/key但不含epoch）。接收/发放都验证key匹配承诺；已知不同epoch复用相同key指纹拒绝，不能把旧bytes换个epoch号伪轮换。
5. `validateCurrentKey(key)` 必须在**每次未来内容发送**与按序原始事件重放时使用：检查公告存在、scope/epoch/密钥承诺、当前audience/水位、冲突锁止，防止只在CLI调用ensure却仍用旧key加密未来内容。旧历史离线解密不拿“今天的policy”重新否定；应在历史原始事件当时的授权状态验证并保留已获旧key。
6. 现版本只分发**当前**epoch；`historyVisibleToNewMembers=true` 下的“有意分享此前历史key”还需显式历史授权流程，不通过本API偷偷给旧期次。默认false隔离已实现；true的历史导入由外层将来补齐。
7. 密钥授权不是读取撤回。拿过旧key/明文的人不能被迫遗忘；退出/ban后不给新epoch并不收回旧key。

## 协议数据格式

### KeyEpochAnnouncement

```json
{
  "body": {
    "version": 1,
    "type": "zaizuo.key_epoch.v1",
    "community": "community-id",
    "conversation": "space#main",
    "epoch": 2,
    "issuer": "pinned-account-id",
    "principals": {"bot-id": "owner-account-id", "human-account-id": "human-account-id"},
    "authorization_events": ["stable-domain-auth-event-id"],
    "audience_hash": "sha256(canonical principals)",
    "policy_hash": "sha256(canonical principals+authorization_events)",
    "key_commitment": "sha256(scoped epoch+random key)",
    "key_fingerprint": "sha256(scoped random key)"
  },
  "signature": "issuer Ed25519 signature over entire body"
}
```

实际摘要为64位小写hex。`authorizeAnnouncement` 验签、校验摘要、钉住issuer、检查当期分发资格及当前授权范围后记录。recipient可以先从控制通道接公告，不必已经持有此期次key。首次合法公告无需社区owner签名。

### KeyGrant

```json
{
  "body": {
    "version": 1,
    "type": "zaizuo.key_grant.v1",
    "community": "community-id",
    "conversation": "space#main",
    "epoch": 2,
    "sender": "pinned-current-member-account-id",
    "recipient_principal": "bot-or-human-principal-id",
    "recipient_account": "owner-account-id",
    "announcement": {"body": {}, "signature": "issuer signature"},
    "envelope": {"body": {}, "signature": "core wrapper sender signature"}
  },
  "signature": "sender Ed25519 signature over entire grant body"
}
```

公告可由A签，持有同key的当前成员B可发grant；只要B也当期合法且使用钉住公钥验签即可。grant额外签名把具体recipient principal映射与公告一起绑定，防止core只对账号封装时被替换bot标签。

core envelope通过 `key.wrapFor(pinnedRecipientPublic, sender: senderIdentity, communityId: communityId)` 生成，包含sender/recipient/community/conversation/epoch与X25519+HKDF+AEAD recipient封装；`receive` 只把已从可信目录解析并通过当前授权的 `authorizedSender` 传给core.unwrap。双层签名都核对，不信任env自报公钥。

### manager metadata

```json
{
  "version": 1,
  "community": "community-id",
  "conflicts": ["scope-with-detected-epoch-fork"],
  "announcements": [{"body": {}, "signature": "..."}]
}
```

只保存签名公告、最高epoch历史与冲突锁止，**不保存key bytes、Identity、signing_seed、exchange_seed**。`fromJson` 为可信本机检查点恢复，验公告签名/摘要/重复epoch承诺，但不重新证明过去成员资格；外层不能把任意远端metadata当可信检查点来钉住更高epoch。新issue/receive/validate仍检查当前policy。

## 运行时推荐接入顺序

```dart
final manager = ConversationKeyManager(service: sharedStateService,
    communityId: community, trustedAccounts: pinnedAccounts);

// 外层先重放已验签成员/房间/ban等控制命令，再处理key公告。
final rotation = await manager.generate(sender: localIdentity,
    conversationId: roomOrConversationId);
// 发布 key.rotate：rotation.announcement.toJson()，外层control加密+设备签名。
// rotation.key只保存在当前设备受保护的密钥存储，不写到公告。

for (final principal in manager
    .resolveAuthorizedRecipients(roomOrConversationId).principalOwnerIds.keys) {
  final grant = await manager.issue(sender: localIdentity,
      key: rotation.key, announcement: rotation.announcement,
      recipientPrincipalId: principal);
  // 发布 key.grant：grant.toJson()，内层仅recipient解得key，外层另验control签名。
}

// recipient设备：
await manager.authorizeAnnouncement(announcement: receivedAnnouncement);
final key = await manager.receive(recipient: localIdentity, grant: receivedGrant);
// 发送或按原始时间顺序重放一条新内容前：
await manager.validateCurrentKey(key: key);
// 然后domain写入口重新验证发言资格。
```

晚到grant可能使先前暂时不可解的content随后可解，外层应重新回放而不是永久丢弃；但必须在原事件顺序对应的成员/公告状态授权。不能用“今天仍成员”直接给新成员旧epoch。

## 冲突 fail-close 与失败边界

- 已知scope同一epoch出现不同key承诺或policy hash，记录 `conflicts` 并抛 `epoch_conflict`。之后generate/issue/receive/validate均停止该scope，不悄悄选择一个key或自己加一继续。
- 没有自动clearConflict接口。外层须先做用户/可信归并裁决、留证并恢复可信检查点；丢弃锁止metadata重启不等于解决分叉。
- 旧epoch回退 `stale_key`；密钥承诺/封装失败 `invalid_key`；当前非成员/未钉住key/身份或签名不匹配 `forbidden`；未知scope或无公告 `not_found`；结构无效 `bad_request`。
- 无中心并发成员可能同时生成同epoch，现原型选择检测后停止，不承诺无冲突分布式epoch分配、全局顺序或强一致成员/配额。缺失/删除公告或本地钉住记录造成的回滚仍依赖外层事件链/信任存储。
- 签名证明来源与完整性，不阻止已授权恶意成员私自复制key/明文。对已知旧key复用做检测不等于证明发送方使用了合格真随机源；生成器使用本机core安全随机。
- 公告/grant若经全社区control通道发布，社区成员可以看到完整接收principal/owner映射、DM关系、feed作者/visibility和期次时间等元数据；只有recipient封装的随机key仍对无关成员保密。当前原型不宣称隐藏内部会话关系；需要关系隐私时须设计定向控制信箱/更少暴露的授权证明。
- 阴影/论坛/朋友圈scope与实际加密通道匹配由外层runtime验证，manager不会把未知范围默认为control或全社区。控制通道本身的加入者密钥分发由外层信任与引导流程解决，不在这里自动发control key。
