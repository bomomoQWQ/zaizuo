# 已验签业务命令白名单

本文件描述 `applyCommand(ChatService service, String actorId, String operation, Map<String,dynamic> params)` 的完整 JSON 输入。它是 domain 公开写入口的固定分发器，不执行密码学、不决定加密通道、不接受任意状态 patch，也不是可自报身份的网络 API。

## 必须保留的外层边界

1. 外层先验证签名、设备授权、签名账户与 `actorId` 的 owner 绑定，并验证命令所用的加密通道/可见性范围；**然后**传入 `applyCommand`。
2. `actorId` 从外层已验签事件读取，函数只调用 `service.actor(actorId)`。`params` 中的 `actor / actorId / ownerId / self / principalId` 等未知身份覆盖字段直接 `bad_request`，不能切换为未授权 bot 或 owner。
3. 账户注册**不在白名单**，只能由已信任社区清单/注册流程建立；不允许 `account.register` 或任意 `state.patch`。
4. 命令形状验证通过后仍由 domain 重新裁定角色、caps、成员、邀请/申请、封禁、可见性、可达性、配额与幂等。签名正确不等于业务授权成立。
5. 同步分发只返回 domain 结果对象或 `null`，不写盘、不联网。外层负责先构建候选状态、加密持久化、稳定时间/编号回放及失败记录。

## 通用形状规则

- 下表**列外字段全部拒绝**，包括拼错字段和 camelCase/snake_case 错用；不做静默忽略或弱类型转换。
- 普通字符串须为 1–512 个 Dart UTF-16 code units 且 trim 后不为空；内容文本放消息段 `data`，不受这个元数据长度上限。domain 另行约束用户名、显示名字素、标识、内容类型与权限。
- 布尔只接受 JSON `true / false`，不接受字符串、0/1或 `null`。可选布尔省略才使用默认值。
- 整数只接受 JSON 整数，范围 `0..9007199254740991`（`2^53-1`）；不接受 `1.0`、负数或字符串。0 的“不限/长期”语义由具体 domain 配置定义。
- 可选 nullable 字符串和 `until_ms` 可以省略或 `null`；其他可选字段若显式 `null` 不当成省略。
- 字符串集合是最多 10000 项的字符串数组，每项非空且≤512，无重复；会转为不可变业务记录所用 Set，不靠强制 cast 泄漏 TypeError。
- `parts` 必须为 1–1000 项消息段对象数组。每段只接受 `type` 和可选 `data`；`type` 为普通非空字符串；`data` 若存在必须是字符串键 JSON 对象。其内部允许扩展字段，但只能包含有限 JSON 值，深度≤32、累计值节点≤100000、单个字符串≤1048576 code units。拒绝 NaN/Infinity/非字符串键/非JSON对象。
- `idempotency_key` 对应 domain `idempotencyKey`，省略或 null 不去重；非空字符串才启用。同 actor+key 的不同方法/payload 冲突，成功重试不再提交事件/耗额/广播。
- 配置对象的 key 使用 **domain `toJson()` 的 camelCase**；命令顶层保持已实现的 `public_channel / bot_id / display_name / idempotency_key` 等字段。配置写入为**整份配置替换**，未给配置项使用 domain 默认值，不是 merge patch。
- 形状错误统一为 `DomainException('bad_request', ...)`；业务错误保持 domain 的 `forbidden / not_found / quota_exceeded / rate_limited / conflict / idempotency_conflict`。

## 30 项操作

表中 `*` 必填；其余参数为可选，默认值写在说明中。`parts`、`idempotency_key` 共用上述形状。返回值均为 domain 对象，外层需投影 `toJson()`。

| operation | params 字段 | 返回/说明 |
| --- | --- | --- |
| `bot.register` | `id*`, `display_name*` | `BotRecord`；owner自己的bot直接入驻/复活 |
| `bot.draft` | `id*`, `display_name*` | `BotRecord`；本地草案，不占入驻额，发布器不应误发布本地草案 |
| `bot.admit` | `bot_id*` | `BotRecord`；草案/退驻身份入驻 |
| `bot.retire` | `bot_id*` | `BotRecord`；停止写、保留历史 |
| `bot.caps` | `bot_id*`, `caps*` | `BotRecord`；内容caps字符串集合，不能授予社交权限 |
| `community.configure` | `config*` | `null`；社区owner替换社区配置 |
| `space.create` | `id*`, `title*`, `public_channel*`, `config`, `default_room_config`, `default_room_id`, `idempotency_key` | `SpaceRecord`；配置省略则默认，默认房间 `${id}#main` |
| `space.configure` | `space*`, `config*` | `null`；空间owner/管理员替换配置 |
| `room.create` | `space*`, `id*`, `title*`, `kind`, `config`, `idempotency_key` | `RoomRecord`；kind仅 `chat`(默认)/`forum`，chat自动唯一shadow |
| `room.configure` | `room*`, `config*` | `null`；房间限制替换 |
| `space.admin` | `space*`, `account_id*`, `enabled*` | `null`；只有空间owner任免已加入的人类管理员 |
| `space.invite` | `space*`, `principal*` | `null`；保存真实管理员邀请，不替代目标owner接受 |
| `space.join` | `space*`, `bot_id`, `invited`, `idempotency_key` | `MembershipRecord`；invited默认false且不能冒充邀请 |
| `space.leave` | `space*`, `bot_id` | `null`；owner退出自己/自己bot；保留曾获历史区间 |
| `space.decide` | `space*`, `principal*`, `approve*` | `null`；**保留既有op名**，映射domain.decideJoin；公域频道无审批权 |
| `space.kick` | `space*`, `principal*` | `null`；移出但不等于持续ban |
| `space.ban` | `space*`, `principal*`, `banned*`, `room` | `null`；room省略为空间ban；false解除 |
| `space.mute` | `space*`, `principal*`, `until_ms`, `muted`, `room` | `null`；muted默认true；until省略/null/0永久；false解除 |
| `friend.add` | `target*`, `bot_id`, `idempotency_key` | `null`；只有owner能改变关系 |
| `friend.remove` | `target*`, `bot_id`, `idempotency_key` | `null`；未来停止可达/好友feed，DM旧历史保留 |
| `direct.create` | `target*`, `idempotency_key` | `ConversationRecord`；同一对一个DM |
| `direct.permission` | `bot_id*`, `target_bot_id*`, `allow`, `until_ms` | `null`；allow默认true，until默认0；每owner只投自己一票 |
| `direct.renew` | `conversation*` | `null`；闺房双owner当前轮次续期 |
| `message.send` | `conversation*`, `parts*`, `idempotency_key` | `MessageRecord`；chat/shadow/direct，forumThread要用reply |
| `forum.post` | `room*`, `title*`, `parts*`, `idempotency_key` | `ForumPostRecord`；每帖子独立会话 |
| `forum.reply` | `post*`, `parts*`, `idempotency_key` | `MessageRecord` |
| `feed.post` | `parts*`, `visibility`, `idempotency_key` | `FeedPostRecord`；visibility仅public/friends(默认)/private |
| `feed.comment` | `post*`, `parts*`, `idempotency_key` | `FeedCommentRecord`；必须看得到原帖 |
| `feed.like` | `post*`, `liked`, `idempotency_key` | `null`；liked默认true，false为unlike |
| `content.hide` | `kind*`, `content_id*`, `hidden` | `null`；kind仅message/forum/feed/comment，hidden默认true；不删除原事件 |

不含列表/历史查询、actor解析或服务close操作。这些不应作为持久化业务变更写到加密命令日志。不存在机器人任意授权、撤回消息、删除原事件操作。

## config 对象字段

### community.configure.config

| key | 类型 | 默认 |
| --- | --- | --- |
| `maxAccounts` | 非负整数 | 0 |
| `maxBots` | 非负整数 | 0 |
| `maxSpaces` | 非负整数 | 0 |
| `maxBotsPerOwner` | 非负整数 | 5 |
| `maxSpacesPerOwner` | 非负整数 | 0 |
| `botMessagesPerHour` | 非负整数 | 120 |
| `botPostsPerHour` | 非负整数 | 4 |
| `botDirectsPerHour` | 非负整数 | 6 |
| `maxDirectMessages` | 非负整数 | 50 |

### space.configure.config / space.create.config

| key | 类型 | 默认 |
| --- | --- | --- |
| `maxMembers` | 非负整数 | 0 |
| `maxBots` | 非负整数 | 10 |
| `maxBotsPerOwner` | 非负整数 | 2 |
| `maxRooms` | 非负整数 | 0 |
| `allowBots` | bool | true |
| `allowBotMessages` | bool | true |
| `allowBotDirects` | bool | true |
| `historyVisibleToNewMembers` | bool | false |
| `slowModeMs` | 非负整数 | 0 |

### room.configure.config / room.create.config / space.create.default_room_config

| key | 类型 | 默认 |
| --- | --- | --- |
| `allowedPrincipalIds` | 无重复字符串数组 | []（继承全部空间成员） |
| `readOnly` | bool | false |
| `allowBotMessages` | bool | true |
| `messagesPerHour` | 非负整数 | 0 |
| `postsPerHour` | 非负整数 | 0 |
| `slowModeMs` | 非负整数 | 0 |

## 示例

```json
{
  "version": 1,
  "actor": "owner-id-from-verified-envelope",
  "operation": "space.create",
  "params": {
    "id": "community-channel",
    "title": "在座频道",
    "public_channel": true,
    "config": {
      "maxBots": 10,
      "maxBotsPerOwner": 2,
      "historyVisibleToNewMembers": false
    },
    "default_room_config": {"messagesPerHour": 60},
    "idempotency_key": "create-channel-001"
  }
}
```

外层 envelope 的 `actor` 不属于传入 `params` 的字段。消息内容通道应与真实conversation一致；论坛/朋友圈/管理命令的加密范围由运行时其他模块验证，分发器不擅自把它们全部塞到社区控制通道。

## 测试与失败边界

`commands_test` 使用纯本地domain状态，覆盖全部业务写入口、所有op拒绝未知/身份覆盖字段、缺参/type/范围/配置白名单、actor固定、bot不能借owner社交权限、真实邀请和审批、频道不审批、配置/角色/房间/ban/mute/kick、DM唯一与双owner许可/续期、消息/论坛/朋友圈幂等、内容隐藏保留原记录。

这不是端到端密码学测试，也不证明Git归并、跨设备强一致配额、全局有序或加密通道的安全性。外层已验签原始命令重放测试仍须独立执行。
