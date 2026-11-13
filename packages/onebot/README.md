# zaizuo_onebot：在座 OneBot 11/12 非界面适配

纯 Dart `dart:io` 包，`zaizuo_domain` 通过 `path: ../domain` 独立依赖。此包是**经过本地测试的核心子集原型**，不是 QQ 实现，不声明完整 OneBot 11/12 兼容，不实现中继协议、加密或前端。实现版本为 `0.1.0`，平台/实现标识为 `zaizuo`，所有新增扩展使用 `zaizuo.` 前缀。

## 接入和身份边界

```dart
import 'dart:convert';
import 'package:zaizuo_onebot/zaizuo_onebot.dart';

// service 由可信宿主完成认证/加载；这里只绑定一个已存在的机器人。
final backend = DomainOneBotBackend(service, botId: 'authorized-bot-id');
final ids = savedMapping == null
    ? OneBotIdMap()
    : OneBotIdMap.fromJson(savedMapping);
final projection = OneBotProjection(backend: backend, ids: ids);
final server = OneBotServer(bindings: [
  OneBotBinding(token: localRandomToken, projection: projection),
]);
await server.start(); // 默认127.0.0.1，port=0分配本机临时端口。

// 停止监听并关闭全部现有WebSocket；projection/backend可由宿主独立持有。
await server.close();
final mappingToPersist = jsonEncode(ids.toJson());
await projection.close();
await backend.close(); // 不会关闭共享ChatService。
```

- 配置为每个 bot 绑定不同本地 token，32～256 个可打印且非空白 ASCII 字符。token 应由可信宿主随机产生、保密并安全保存；测试中仅使用虚构 token。
- 每个 HTTP 请求根据 `Authorization: Bearer <token>` 选择**预先配置好的固定绑定**，WebSocket 在 upgrade 前鉴权并永久绑定该 bot。不接受自报身份切换。`self` 出现在请求外层或 params 时都必须匹配；11 `self_id` 也必须匹配对应映射。12 越权返回 `10102`，11 返回 `1403`，元动作同样检查。
- 拒绝任何 `Origin`，拒绝 URL 查询串（包括 `access_token`）、fragment/userinfo，禁止浏览器直接调用。默认只监听 `127.0.0.1`，显式地址也只能为环回 IP。
- `DomainOneBotBackend` 每次经 `service.actor(botId)` 领取当前合法 bot Actor；请求不能构造 Actor、不能继承 owner 管理权限；发送、列表、历史和事件都经过 domain 检查。事件在接收时过滤，尚未轮询的事件在取出时再次检查权限。
- 任意实现 `OneBotBackend` 的自定义后端也必须遵守相同权限边界；它不是不鉴权的万能 handler。

## 传输端点

| 方法 | 端点 | 含义 |
|---|---|---|
| POST | `/onebot/v11/<action>` | v11 JSON 参数对象，例如 `{"group_id":1,"message":"hello"}`；可附 `echo` |
| POST | `/onebot/v11` | v11 动作 envelope，`{"action":"get_login_info","params":{},"echo":...}` |
| GET upgrade | `/onebot/v11` | v11 universal WS，同一连接请求动作并收事件 |
| POST | `/onebot/v12` | v12 动作 envelope，`params` 必须是对象 |
| GET upgrade | `/onebot/v12` | v12 universal WS，同一连接请求动作并收事件 |

所有请求为 UTF-8 JSON；HTTP Content-Type 必须为 `application/json`。11 `echo` 任意 JSON（含 null）原样保留；12 只接受字符串并原样保留（空字符串也可）。11 可省无参数动作的 `params`，12 不可以。12 字符串消息是纯文本，绝不解析 CQ。

安全收紧故意不同于官网的一些通用部署选项：不接受 URL token、不支持 v11 GET 动作/urlencoded 表单、不支持公开监听；v11 原 `/api`/`/event`/`/` 路径在本包统一挂载到版本化 universal 端点。它们是公开的子集/安全配置差异，不应声称完整实现所有通信方式。

## 已支持动作和消息

**11**：`send_msg`、`send_private_msg`、`send_group_msg`、`get_login_info`、`get_friend_list`、`get_group_list`、`get_group_member_list`、`get_msg`、`get_status`、`get_version_info`。

**12**：`send_message`、`get_self_info`、`get_user_info`、`get_friend_list`、`get_group_list`、`get_group_info`、`get_group_member_list`、`get_supported_actions`、`get_status`、`get_version`、`get_latest_events`。

有 `OneBotChannelBackend` 能力的后端（包括已提供的 domain adapter）额外支持 12：`get_guild_list`、`get_guild_info`、`get_channel_list`、`get_channel_info` 和 `send_message(detail_type=channel)`。

- domain 的每个可读 `chat`/`shadow` **会话**分别映射为 11/12 group；茶会不会错投普通主房间。12 同时支持标准两级映射：`guild_id = space.id`，`channel_id = conversation.id`。频道列表只列出有当前权限的 chat/shadow；`joined_only` 在域内没有独立频道加入状态，因此“已加入”与空间/房间可读权限一致。12 接收事件优先使用 `message.channel`。
- 私聊保留双方原生主体身份，不把机器人发送身份替换为 owner。业务时间为 UTC Unix 毫秒；11 边界返回整数秒，12 返回浮点秒。12 self 有 `user_id/user_name/user_displayname`，用户列表增加标准 `user_remark`，没有数据的显示名/备注为空字符串。
- 消息核心段：11 `text/at/reply`，12 `text/mention/mention_all/reply`；数组、单段对象都接受。11 字符串支持 CQ 转义与 `auto_escape`，CQ 解析先识别边界再一次解码实体，`&amp;` 最后解。11 消息段 ID 引用经稳定映射转换，12 使用原生字符串 ID。
- 完整配置可信媒体后端时支持图片/文件引用与受限 data 上传/下载（见下文）；未配置媒体、其它媒体/富文本、未识别消息段/段参数明确返回 unsupported/bad segment 错误。不把任意 URL 保存成功冒充文件发送，也不直接输出内部附件描述符。
- bot 发送成功不伪装成“机器人收到用户消息”：额外上报 `notice` / `zaizuo.message_sent`，携带 `zaizuo.detail_type`。来自其它主体的消息使用标准 message 事件。WS 首事件为 11 lifecycle/connect 或 12 meta/connect；12 随后有初始 status_update，并以 pingInterval 检查状态变化。默认不产生应用层 heartbeat 事件，仍有 WS ping/pong。
- `get_supported_actions` 返回真实子集，能力不同列表不同；版本返回 `zaizuo.compatibility: subset`。`delete_msg` / `delete_message` 明确报不支持（11 `1404`，12 `10002`），不假成功。

### 原生论坛/朋友圈扩展（11/12 同期可调）

有可选 `OneBotSocialBackend` 能力的后端（包括 domain adapter）额外提供下列**在座扩展**，不是 OneBot 标准动作。`get_supported_actions` 与 11 版本信息会按后端真实能力列出，不安装此能力即明确 unsupported。

| 动作 | 严格允许的参数（除 self 外） | 返回 |
|---|---|---|
| `zaizuo.post_forum` | `room_id`、`title`、`message`、可选 `idempotency_key` | 帖子原生 ID、标题、内容、会话 ID、作者、时间；自身发布回执不夹带历史回复 |
| `zaizuo.reply_forum` | `post_id`、`message`、可选 `idempotency_key` | 对应帖子、回复消息 ID/会话/原发送人/内容/时间 |
| `zaizuo.get_posts` | `room_id`、可选 `limit`、`before_id` | 可见帖子从新到旧；每项含正文与最近可见回复窗口（最多 50） |
| `zaizuo.post_feed` | `message`、可选 `visibility`、`idempotency_key` | 自身朋友圈原生 ID、作者、可见范围、内容、时间 |
| `zaizuo.get_feed` | 可选 `author_id`、`limit`、`before_id`；或仅 `post_id` | 可见朋友圈，含可见评论（最近 50）、点赞者 ID、内容和时间 |
| `zaizuo.comment_feed` | `post_id`、`message`、可选 `idempotency_key` | 评论 ID、帖子 ID、原作者、内容、时间 |
| `zaizuo.like_feed` | `post_id`、可选 bool `liked`、`idempotency_key` | 固定 bot 的点赞/取消点赞状态 |

- 两版本的扩展编号都为**原生字符串 ID**，不混用 11 数字群/消息编号。扩展结果 `time` 都是 UTC Unix 浮点秒，消息数组均使用内部标准语义（如 mention/user_id），11 输入字符串仍支持 CQ，12 字符串始终纯文本。
- `limit` 为 1～100，默认 50；`before_id` 必须为当前可见结果中的游标，不能借隐藏游标探测私有记录。`post_id` 单项读取不能同时传列表过滤。帖子回复窗口用 `zaizuo.reply_window: 50` 标记，朋友圈评论截断用 `zaizuo.comments_truncated` 明示；不宣称无限完整历史。
- 扩展请求外层和 params 都有白名单；未知动作/字段拒绝，不接受 `actor/bot_id/sender_id/url` 等身份或抓取覆盖字段。所有动作仍固定到凭据绑定 bot，domain 权限、cap、限额和可见范围独立检查。
- 朋友圈 `public/friends/private`、论坛房间访问/历史区间、隐藏帖子/评论都由 domain 授权列表过滤；禁止评论/点赞不可见的 private/friends 内容。仅有 post 能力而无 history.read 的 bot 可以收到它自己刚发布的回执，但不能借回执读取其它历史回复/评论。
- 本轮只做显式动作和授权查询，尚不广播 forum/feed 专用事件；标准 `send_message` 和普通消息事件不会把论坛帖子误投到默认房间。图片/file_id 等媒体段未接入验证后端时仍明确 `10005`（11 映射 `1400`），不自动抓 URL，也不假装完成媒体发送。

### 图片/文件 data 上传、下载与消息引用

媒体是可选 `OneBotMediaBackend` 能力：只有 `mediaEnabled=true` 时才出现在支持动作列表，domain adapter 要求下述四个主 hook 全部配置。部分配置/未配置时，image/file 段明确返回 `10005`，不会当普通 JSON 保存成功冒充已完成媒体发送。

| 版本 | 动作 | 严格参数与结果 |
|---|---|---|
| 12 标准子集 | `upload_file` | `{type:"data",name,data:规范Base64,sha256?:小写SHA256,"zaizuo.mime"?:MIME,"zaizuo.purpose"?:"image"或"file"}` → `{file_id}` |
| 12 标准子集 | `get_file` | `{file_id,type:"data"}` → `{name,data:Base64,"zaizuo.mime","zaizuo.size"}` |
| 11 在座扩展 | `zaizuo.upload_file` / `zaizuo.get_file` | 同上；不虚构标准 11 `upload_file` 动作 |

- 仅 `type=data`；明确拒绝 URL、path、headers、数据 URI、CQ `base64://` 和本机路径读取，不进行任意 HTTP 抓取或文件打开。`file_id` 只接受 1～512 个 ASCII 字母数字或 `_.~-` 的 opaque ID（不是自报 scope）。
- 默认最大单文件 **8 MiB**，宿主可用 `maxMediaBytes` 配置。Base64 在解码前检查编码长度、规范字符/padding，解码后检查大小与规范性；大包用线性扫描，避免递归正则栈溢出。可选 `sha256` 在交付宿主前验证，不接受错误校验和。
- 文件名最多 256 个 Unicode 字符；去除控制字符，替换路径分隔符和 Windows 危险字符，处理保留设备名。名字仅元数据、不是此包可打开的路径。MIME/purpose 明确独立，image purpose 要求 image MIME，可信宿主仍须验证真实内容/用途，不能因扩展名就声称图片解码安全。
- 12 `image/file` 输入只含 `file_id` 及可选 `name/mime`；11 image/file 同时允许 CQ `file=opaque-id`（file 段为在座扩展），不接受 URL/path。输入 `name/mime` 不决定授权，最终元数据由可信后端确认。
- 先确定 private/group/channel 或 forum/feed 真实目标，并在独立 domain 候选快照预检当前 bot 的身份/cap/发送权限，再进入可信解析。宿主必须验证 source ID 当前 bot 可使用，并按**目的 scope 当前 epoch**处理，不能把旧 descriptor 直接转发或信任请求的 scope。
- 内部持久化媒体形状为 `{type:"image"|"file",data:{attachment:{scope,epoch,descriptor}}}`，不得含上传源 ID、明文 Base64 或任意自报路径。Node 可在 execute 中统一解析一次，resolver 先保留已验证 opaque 引用；此模式必须提供相应 committing handler。提交后投影仍严格要求 scoped encrypted attachment，不能未解析就假成功。
- 接收事件/历史/论坛/朋友圈结果会 **await** `projectMediaParts`，只输出后端新签发的 `file_id/name/mime`，不透传 descriptor/key/epoch。get_file 必须由宿主再次校验当前 bot 的消息或 feed 可见性，再解密；同一 ID 不因知道编号就授权另一个 bot。
- 异步事件按到达顺序串行投影，不先发缺附件消息再补。待投影队列默认 32，满时报 degraded 而不是无限积压；不承诺零丢失。媒体 hook 默认 30 秒超时，超时后该 adapter 媒体操作永久 fail-closed，须由宿主核对状态并重启，防不能取消的 Future 持续累积。

**显式扩容传输**：原 `OneBotLimits()` 默认保持 64 KiB。启用完整 8 MiB 文件应显式用 `OneBotLimits.media()`（HTTP/WS 共用），wire cap 为 `ceil(maxMediaBytes/3)*4+65536`；默认 TCP 连接 8、同时 HTTP 2、WS 动作/发送队列各 2；projection 另限媒体动作并发 2。可在工厂传 `maxMediaBytes/maxConnections/maxHttpRequests`，仍有首部/正文/帧/超时/速率上限，不是无界上传。大 JSON 返回同样受 wire cap；真实部署需评估并发内存占用而非仅单文件上限。

### ID 映射持久化

11 使用独立 `user/group/message` 命名空间逐一分配正整数，最大 `2^31-1`；不用截断 hash、不碰撞、不重用、耗尽报错。12 保留原生字符串 ID。一个 `OneBotProjection` 同时服务两版本，12 发出的 message 也同步登记 11 映射，11 `get_msg` 可稳定读取。

同一内核的多个 projection 应共享一个 `OneBotIdMap` 实例。宿主须将**完整映射**与业务状态一同可靠保存，再在启动接收请求/事件前用 `OneBotIdMap.fromJson` 或 `loadState` 载入；`toJson/exportState` 只导出数据，不代替原子写盘。不保存映射或用旧映射恢复，不能宣称重启后整数编号稳定；仅从历史重新遍历不保证相同分配顺序。持久化清单不能只在 HTTP 发送时保存：WS 新事件/列表/mention/reply 的投影也可能分配编号。

可在 `OneBotIdMap` 构造、`fromJson`、`loadState` 传 `onChanged: (Map<String,dynamic> state) { /* 同步可靠保存 */ }`，每次新分配在返回/发布前同步执行。不能传 async 回调：实现会显式检测 Future 并拒绝。回调失败会回滚本次未发布分配，并使该实例永久 `persistenceFailed` / fail-closed（后续动作失败、停止事件投影）；因为回调可能部分写入，必须由宿主核对磁盘真相后创建新实例恢复，不能继续分配并重用候选编号。映射本身可能暴露关系，应仅存在本机安全存储、不入 Git；此包不代替宿主的原子文件替换与加密。

## 事件、队列和时间完整性边界

默认限制（配置必须为正，长轮询上限可为 0）：

| 项目 | 默认 |
|---|---|
| TCP/WS 连接 | 64 |
| 同时 HTTP 请求 / projection 未完成动作 | 各 32 |
| 首部 / 正文或 WS 消息 | 16384 / 65536 字节 |
| WS 待处理动作 / 待发送 | 16 / 32 条 |
| WS 速率窗口 | 10 秒 100 请求，含错误请求 |
| 首部完整到达 / 正文完整到达 | 各 5 秒 |
| 动作 / 写入或关闭宽限 / WS ping | 35 / 5 / 30 秒 |
| HTTP 事件缓冲 / 最长长轮询 | 256 条 / 30 秒 |

- 在 HTTP 解析器之前限制首部大小和完整到达时间，HTTP 不保持 keep-alive；正文还有解码限制、wire 字节总上限和到达期限。WS 关闭压缩，帧声明长度和跨 continuation 累计长度在交给 `dart:io` 解码前检查，防止巨大声明先无界分配。
- WS 队列溢出/慢写用应用关闭码 **3013**（当前 `dart:io` 将 1013 视为保留码，不能直接发送）；速率超限 1008。原始帧/首部/正文资源超限可直接终止 TCP，收到异常或断线不应重试成“已成功”。
- 过大正文或取消 chunked 正文时，Dart 可能直接终止连接，不能保证给已拒绝的大包写 JSON 错误；正常解析后的动作错误按协议 retcode 返回。
- 12 HTTP 轮询缓冲独立于 WS，按本地到达顺序从旧到新取走；并发第二个长轮询返回 `35004`。缓冲满丢最旧，`get_status` 的 `zaizuo.dropped_events` 暴露累计丢弃数。缓冲不持久化、不自动断线重放。
- 动作超时后底层异步后端可能仍完成（错误明示 `outcome may be unknown`）；projection 保持未完成动作计数，不能靠反复超时绕过并发上限。调用方应在业务层实现幂等和结果核对。
- 没有跨设备全局全序、可靠事件游标、历史无缺口、零丢失、exactly-once 或公网投递承诺。WS 成功发送也不等于客户端持久化；内部 timestamp 转秒不消除并发、同时间事件、时钟漂移或断线期间缺失。domain 的不可变原始消息与消息 ID 是查询真相，不能把本机事件队列当可靠同步协议。

## 可选持久化 runtime 接口

`DomainOneBotBackend(service, {botId, sendHandler, directResolver, serviceProvider, messageStream, commandHandler})`：

- `DomainSendHandler` 是 `FutureOr<MessageRecord> Function({required Actor actor, required String conversationId, required List<Map<String,dynamic>> parts})`；可信宿主可先落盘/签名再返回。
- `directResolver` 是 `FutureOr<String> Function(String targetId)`；私聊先 await 此函数获得已经持久化且具有独立密钥的 DM 编号，再调用 sendHandler。未提供则调用普通 `service.directConversation`（纯内存模式）。
- `serviceProvider` 可在持久化重放后返回新 ChatService，避免抓旧指针。若使用 provider，应同时提供稳定的 `messageStream`，adapter 不会自动重新订阅被更换服务的广播。
- `messageStream` 可只推“已经持久化提交”的 MessageRecord；adapter 收到仍会重新检查当前 domain 读权限。默认直接监听 domain 的内存提交流，不声称已落盘。
- `DomainCommandHandler` 为 `FutureOr<Map<String,dynamic>> Function(String operation, Map<String,dynamic> params)`，覆盖论坛/朋友圈写命令；未提供则默认调用同一可信本地 domain。宿主必须把该回调绑定到同一个 bot，运行 runtime 命令后更新 provider，并返回命令的 `result`（record.toJson），不能返回整个 event envelope。adapter 按已提交 state 复核结果 ID/原作者/所属帖子，失败不会假成功。
- commandHandler 白名单：`forum.post {room,title,parts,idempotency_key?}`、`forum.reply {post,parts,idempotency_key?}`、`feed.post {parts,visibility,idempotency_key?}`、`feed.comment {post,parts,idempotency_key?}`、`feed.like {post,liked,idempotency_key?}`；省略未提供的幂等键，**不含任意 Actor/owner**。`feed.like` 可以返回空 Map，其它应含结果的原生 `id`。查询始终走 domain 授权 API，不把 state maps 当不受限列表。
- 媒体构造参数：`mediaUploadHandler`（`{Actor actor,String name,List<int> bytes,String mime,String purpose}` → `FutureOr<Map>`）、`mediaGetHandler`（`{Actor actor,String fileId}` → `FutureOr<Map>`）、`resolveMediaParts`（`{Actor actor,String conversationId,List<JsonMap> parts}` → `FutureOr<List<JsonMap>>`）、`projectMediaParts`（`{Actor actor,MessageRecord message}` → `FutureOr<List<JsonMap>>`），上述具名字段均 required。upload hook 返回 `{file_id}`，get hook 返回 `{name,mime,size,data:Base64}`；额外字段不会向外透传。
- 可选 `mediaScope({required Actor actor,required String operation,required Map<String,dynamic> params}) → FutureOr<String>` 用于 forum room/feed scope，必须与 domain 真实目标一致；`maxMediaBytes=8MiB`、`maxPendingMediaEvents=32`、`mediaOperationTimeout=30s`。论坛用真实 MessageRecord，feed/comment 用其原生 record ID、实际 feed scope、原作者和 parts 合成只读 MessageRecord 交 project hook；宿主需按对应 record 类型授权。
- 宿主须让 resolver/handler/provider 的持久化和状态切换一致；hook 是可信集成点，不是可由 OneBot 请求任意选择的回调。此包测试用内存可信媒体宿主验证协议/授权边界；实际附件加密、密文对象存储和 scope key 由 runtime/core 实现，不据本包测试单独宣称加密安全。

## 反向 WebSocket

默认禁用。构造 `ReverseWebSocketConfig(url: ..., version: 11或12, token: ..., trustedUrls: {精确Uri}, enabled: true)`，然后 `OneBotReverseClient(...).start()`。

- URL 必须在本地精确 allowlist 中、无 userinfo/query/fragment，只能 ws/wss。`ws` 只允许**数字环回 IP**（不接受 `localhost` DNS）；其它主机必须为显式受信 `wss`，使用系统 TLS 证书验证，不跳过证书检查。
- 使用直接 TCP/TLS 和一次受限升级握手，不走代理、不跟随重定向；不会把 Authorization 发送到 302/307 指向的第二个目标，也不允许事件/动作字段更改 URL。11 发送 `X-Self-ID/X-Client-Role: Universal`，12 发送 `User-Agent` 和 `Sec-WebSocket-Protocol: 12.zaizuo`。
- 可取消定时重连；close 关闭现有 WS、连接中的 TCP 与等待计时器，停止后不会继续重连。生产部署的 WSS/证书轮换、真实代理/NAT、网络漂移未在此轮实测。allowlist 是宿主可信配置，不保护被恶意篡改的配置本身。

## 真实未支持范围

- 删除/撤回；好友/入群/管理/禁言等 OneBot 写动作；标准消息接口的 forumThread 投影（使用上述 zaizuo. 原生扩展发帖/回复/朋友圈，不会误发默认房间）。
- 除上述 text/mention/reply 和可选 image/file 外的消息段；语音/视频/位置/转发/媒体转码、URL/path 上传下载、分片上传下载；不抓取任意 URL。图片/文件 data 及 opaque 引用已支持，但实际持久化加密需可信 runtime 媒体后端。
- v11 `_async` / `_rate_limited` 后缀、GET API、表单 API、专用 `/api`/`/event` 连接；HTTP webhook/HTTP POST 事件推送/快速操作；MessagePack。
- 频道成员专用动作、guild/channel 修改/退出；非消息业务 notice/request 事件；完整实时账号登录生命周期（状态是本地业务可用性，不代表已连接外部平台）。
- SDK Flutter/Android 前后台与系统通知、真实账号、TLS 生产部署、密码学/端到端安全审计、生产负载/长时间慢收端压力测试。

## 本机测试

本轮 Dart 3.14.0：`dart analyze` 无问题，`dart test --reporter expanded --timeout 30s` **57 项通过**；全部网络测试只监听环回地址，未使用真实凭据。

覆盖双版本同 bot 收发与跨版本消息映射；11 任意 JSON/12 string echo；未认证/Origin/URLtoken/self 越权；domain permissions 映射；好友/群/频道查询；WS 消息事件与独立 get_latest_events/长轮询/缓冲溢出；反向 11/12 握手/动作/事件/断线重连/关闭/禁止重定向；CQ 转义；首部大小/超时、超额正文、WS 动作队列、巨大帧声明；持久化 hooks 与 serviceProvider 重放切换；11/12 论坛与朋友圈发布/回复/评论/点赞/取消/查询、public/friends/private 权限、隐藏记录与分页、扩展字段白名单、commandHandler 参数与失败、HTTP/反向 WS 原生扩展；HTTP/WS 双版本媒体上传/引用/下载、跨 bot/cap/会话授权、URL/path/校验和/Base64/大小拒绝、异步投影顺序、forum/feed 媒体、Node 延迟一次解析、精确 8 MiB 数据边界及媒体并发。没有把这些短时本机测试当作时间完整性或生产可靠性证明。

Windows 工具环境若系统 TEMP/telemetry 目录拒绝访问，可为**本次进程**配置包内 `.dart_tool/local-runtime` 的 TEMP/TMP/APPDATA/LOCALAPPDATA，设置 `DART_SUPPRESS_ANALYTICS=true` 和仓库 `.local/pub-cache`；不改系统 PATH、不修系统目录权限、不另下载 SDK。

## 官网核对依据

本轮按官网逐页核对，安全收紧/未实现项已在上文明确：

- 11 [HTTP](https://11.onebot.dev/communication/http.html)、[WS / echo](https://11.onebot.dev/communication/ws.html)、[反向 WS](https://11.onebot.dev/communication/ws-reverse.html)、[公开 API](https://11.onebot.dev/api/public.html)、[消息事件](https://11.onebot.dev/event/message.html)、[CQ 转义](https://11.onebot.dev/message/string.html)、[元事件](https://11.onebot.dev/event/meta.html)。
- 12 [动作请求](https://12.onebot.dev/connect/data-protocol/action-request/)、[动作响应/错误码](https://12.onebot.dev/connect/data-protocol/action-response/)、[HTTP](https://12.onebot.dev/connect/communication/http/)、[WS](https://12.onebot.dev/connect/communication/websocket/)、[反向 WS](https://12.onebot.dev/connect/communication/websocket-reverse/)、[元动作](https://12.onebot.dev/interface/meta/actions/)、[元事件](https://12.onebot.dev/interface/meta/events/)、[用户动作](https://12.onebot.dev/interface/user/actions/)、[群动作](https://12.onebot.dev/interface/group/actions/)、[消息动作](https://12.onebot.dev/interface/message/actions/)、[消息数据类型](https://12.onebot.dev/interface/message/type/)、[消息段](https://12.onebot.dev/interface/message/segments/)、[频道动作](https://12.onebot.dev/interface/guild/actions/)、[频道事件](https://12.onebot.dev/interface/guild/message-events/)、[文件动作](https://12.onebot.dev/interface/file/actions/)。
