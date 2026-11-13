# 在座：非界面 runtime / CLI

这是可运行的非界面 Dart 原型，串起签名社区名册、每设备加密事件、Git 同步、密文图片/文件按需传输、可选哑中继与 OneBot 11/12 本机投影。**不是正式 Flutter IM 页面、QQ/微信客户端或 NapCat 插件；没有接入真实第三方平台。** 当前图片/文件已由真实编码器、会话重新加密、Git附件对象、按需获取及授权解密贯通，并在Windows/Ubuntu跨机验证，不再仅保存image JSON段。

## 运行环境与秘密

需要 Dart SDK、系统 Git（原型测试为 Dart 3.14 / Git for Windows 2.55）。在本包目录先准备依赖，再执行：

```text
dart run bin/zaizuo.dart help
```

密码只能通过当前进程环境 `ZAIZUO_PASSWORD` 传入，不出现在 argv。OneBot 与中继令牌分别用 `ZAIZUO_ONEBOT_TOKEN` / `ZAIZUO_RELAY_TOKEN`，至少 32 个可打印 ASCII 字符；不要使用真实平台令牌。凭据环境不写进 Git 或错误输出，CLI 只报告稳定错误码/类型，不打印任意异常、堆栈、正文或 token。

本机资料目录包含设备私钥密文、仓库外 unlock factor、恢复材料、明文 ID 映射及密文事件：**绝不能整个 git add、同步到共享盘或当作受管 Git worktree**。恢复材料需离线保管；桌面文件不是 Android Keystore、Windows DPAPI 或经审计账户恢复协议。自动清理恢复文件由用户明确决定，不擅自删除。

## 命令

```text
init <资料目录> <账号名> <昵称>
join-init <目录> <账号名> <昵称> <外部manifest JSON文件> <仓库外根指纹>
join-request <目录> [输出JSON文件]
admit <根账户目录> <请求JSON文件> [输出manifest文件]
status <目录>
command <目录> <操作名> <参数JSON文件> [显式加密通道]
send <目录> <会话编号> <文本>
send-file <目录> <会话编号> <本机文件> [MIME]
send-image <目录> <会话编号> <本机图片>
messages <目录> <会话编号> [数量]
download <目录> <本机file_id> <明确输出路径>
sync <目录> [受管同步目录 Git远端]
serve <目录> <机器人编号> [本机端口]
```

- `init` 创建新社区根账户与本设备，默认强密码/KDF，不下载 SDK、不访问远端。
- `join-init` 必须提供来自已知社区的公开签名 manifest 和**仓库外核验**的根指纹，不能从同一个未知仓库自报根自动信任。新账户此时只是待入驻本机资料。
- `join-request` 导出由本账户签名的公开账号/设备加入请求，不导出私钥或密码。
- `admit` 由社区根账户明确接纳请求，形成下一 revision 名册。配置 Git 后先获取既有名册，再发布连续历史；不自动批准陌生请求。非 root 不能签名维护 `main`。
- `status` 输出本地社区/设备/事件数量与后台状态；不是远端连通性或已送达证明。
- `command` 执行 runtime 白名单命令（例如 `bot.register`、`space.create`、`space.join`、`room.create`、`forum.post`、`feed.post`）。参数只从 JSON 文件读取，主体固定当前本机账户。默认由 `replica.routeFor` 自动选择控制/房间/论坛/朋友圈通道；显式通道仍必须通过 replica 路由验证。
- `command ... bot.draft <参数JSON>` 是**纯本机草案**例外：参数仅 `id/display_name`，存入本机加密且签名的私密资料，不 append 事件、不走控制通道/Git/relay，也不占社区入驻配额；返回 `local_only: true`、草案 `result`，没有 `event_id`。草案 ID 不得与现有主体或其他本机草案冲突。
- `command ... bot.admit <参数JSON>`（仅 `bot_id`）对本机草案转换为真正 `bot.register`，通过当前社区/每 owner 入驻配额和权限校验、加密事件落盘成功后才删除私密草案；失败保留草案。其他设备看不到本机草案，只能在入驻后收到公开注册事件。旧共享日志中已存在的非本机草案 admit 保持兼容，但新草案禁止进共享日志。
- `send` 发送普通文本消息到已获授权的具体会话。需先存在会话、成员关系及合法当前期次密钥，不能用控制通道绕过私密范围。
- `send-file` / `send-image` 读取当前用户明确选择的本机普通文件（默认最多8MiB），图片检查尺寸/像素并转为lossless WebP；暂存加密后按目的scope/epoch重新加密。有Git时先发布密文附件对象再发布消息引用；不接受机器人提供的任意URL/路径。
- `messages` 查询当前账户可读消息，将附件投影为本机主体专用 `file_id`；配置Git时先同步。`download` 按该句柄重查原消息权限并按需获取/解密对象，只保存到用户明确输出路径，拒覆盖已有文件，不采用远端name选择路径。详见[媒体管线](<MEDIA.md>)。
- `sync` 获取完整签名名册链，逐 revision 调用 `profile.acceptManifest`、更新相同 trust 对象和 replica seed/keys，然后拉取验签密文、重放、给当前合法接收者生成必要新 epoch/grant，最后发布本设备已落盘日志。重复同步幂等，不重写别的设备 branch。
- `serve` 固定绑定当前账户自己的一个已授权 bot，启动环回 OneBot HTTP/WS 11/12。请求自报 owner/self 不能切换身份；bot 不继承 owner 私聊权限。聊天、论坛、朋友圈写入均经过同一个加密持久化 execute 入口，不只改内存。

示例（参数文件自行在私密本机目录准备，不包含口令）：

```text
dart run bin/zaizuo.dart init <私密资料目录> alice 爱丽丝
dart run bin/zaizuo.dart command <私密资料目录> bot.register <bot参数JSON>
dart run bin/zaizuo.dart command <私密资料目录> space.create <频道参数JSON>
dart run bin/zaizuo.dart command <私密资料目录> space.join <bot加入参数JSON>
dart run bin/zaizuo.dart sync <私密资料目录> <另一个空受管目录> <本机裸仓库绝对目录>
dart run bin/zaizuo.dart serve <私密资料目录> <bot编号> 6700
```

公开频道无需人工审批加入不等于社区账号无需根名册接纳，也不等于密钥永远即时送达。私有范围不因 Git 仓库私有而自动隔离；由密钥受众/epoch 校验约束。

## serve 后台配置

- `ZAIZUO_GIT_REMOTE` + `ZAIZUO_GIT_WORKTREE`：必须成对配置。worktree 必须是空专用同步目录或本适配器创建的同一目录，不接管普通用户仓库。远端只允许现存本机裸仓库绝对目录、无内嵌密码/token 的 HTTPS/SSH URL；网络凭据依赖系统 Git credential helper / ssh-agent，见 core Git 文档。
- `ZAIZUO_SYNC_INTERVAL_SECONDS`：默认 `30`，整数且至少 `1`。每轮结束后才排下一次 timer，不是重叠的 `Timer.periodic`。手动并发 `syncOnce` 共享同一轮，命令、名册接纳、私密资料保存与同步串行。
- `ZAIZUO_ONEBOT_TOKEN`：固定 bot 的本机访问令牌。仅监听 `127.0.0.1`，默认端口 `6700`，测试可用 `0` 分配临时端口。无公网监听参数、不改防火墙。
- 可选 `ZAIZUO_RELAY_URL` + `ZAIZUO_RELAY_TOKEN`：只接受 `ws://127.0.0.1:端口/v1/ws` 或其他数字 loopback 地址，无 hostname/DNS/public/WSS/redirect。本命令不启动中继服务器；需要用户另行启动本机测试中继。

没有配置中继、初次中继不可达、运行中掉线，都不会停止定时 Git。中继订阅控制通道及已知 keys/事件中的 scope 对应哈希 topic；最多 64 个，超过时**关闭中继并报告降级，继续 Git，不截掉部分 topic 冒充完整同步**。hash topic 不含明文会话名，但仍有可猜测与流量元数据。

中继只发送已在本机 store flush 的本设备原密文信封，不重新加密，不转发收到的其他设备分支来改写来源。中继 `ok` 只代表中继处理 publish，**不代表收件人收到、验签、写盘或 Git 持久化**。断线、队列/大小上限失败的事件依靠 Git 补齐；中继不承担历史存储或无限离线队列。

Ctrl+C / Unix SIGTERM 会停止新 timer 和监听，等待已启动命令、Git 同步、store/private 写入及中继导入完成后关闭资源。Git 当前没有进程硬超时，因此断网 Git/helper 可能延长退出等待；不要把强杀等同于正常完成。OneBot 11 ID 映射通过同步 `onChanged` 临时文件 flush+rename，在返回成功前就落盘，不依赖退出时一次性保存。

## Node API

```dart
final node = await ZaizuoNode.open(
  profile: profile,
  git: managedGit, // 可选；借用时调用方负责关闭
  syncInterval: const Duration(seconds: 30),
  relayUrl: optionalLoopbackUri,
  relayToken: optionalRelayToken,
);
await node.execute(operation: 'space.join', params: {'space': spaceId});
await node.syncOnce();
await node.start(botId: fixedOwnedBotId, token: localOneBotToken, port: 6700);
await node.close();
```

`open` 拥有自己打开的 store/replica；`ownsGit: true` 时也负责关闭传入 Git。可监听 `node.errors` 的稳定错误码和查询 `status()`；命令失败必须传播，不能把 store/replica/名册错误当作成功。profile trust 与 FileEventStore trust 为同一对象，仅接受通过外部 root pin 和完整 revision 链校验的名册；本原型只实现 additive 入驻，移除/吊销/换钥不可宣称已完成自动安全更新。

## 验证与已知边界

```text
dart test test/node_test.dart --reporter expanded --concurrency 1
```

测试仅本机临时目录/裸 Git/数字环回 HTTP、WebSocket，不使用真实账号密码/token、真实托管远端、NapCat 或公网端口。覆盖 Node 自动路由和私密 keys 保存、固定 bot social commandHandler、映射重启、签名 main 入驻先于事件、同轮同步合并、定时 Git 无中继运行、relay 失败后 Git 仍工作、关闭停止调度与 topic 上限降级。

这是未审计非界面原型：不承诺零丢失/严格全序/无限容量/全量 OneBot 兼容。Git 全历史重验、native 文件锁、多文件崩溃耐久、移动端系统 Git/后台调度/耗电、Android安全存储需要独立验收。尚未接入真实第三方平台或真实图片/附件平台链路，不把本地 JSON 消息段成功误称为平台收发完成。
