# 图片与文件：本机媒体管线与验收

本页说明 runtime 的 `MediaRepository` / `ZaizuoNode` 媒体 API，以及真实双资料目录、裸 Git 的集成测试范围。它不是外部平台图片支持、跨电脑 SSH、安装包或生产安全审计的验收证明；那些链路须单独运行并记录结果。

## 发送与接收

媒体先进入本机加密暂存，再在发送时以目的范围的当前会话密钥**重新加密**。上传得到的 `file_id` 是本机特定主体的随机句柄，不是 Git 对象 ID、磁盘路径、可转发全局 bearer URL 或解密 key。

```dart
final uploaded = await node.media.upload(
  actorId: actorId,
  name: 'document.bin',
  mime: 'application/octet-stream',
  bytes: fileBytes,
  purpose: 'file', // image 时按图片管线转换
);
final result = await node.execute(
  actorId: actorId,
  operation: 'message.send',
  params: {
    'conversation': authorizedConversation,
    'parts': [
      {'type': 'file', 'data': {'file_id': uploaded['file_id']}},
    ],
  },
);
```

不要把消息 `data` 手工替换成远端 URL、任意路径、`base64://`、他人句柄或自己构造的 `attachment`。发送入口只接受受控 `file_id`（可选受支持的 metadata 字段），先验证该动作的业务权限，再解析句柄和原记录读权限，最后仍由 replica 执行已认证主体、正确路由、当前 epoch 校验和加密日志落盘。

接收方先通过已验证名册与 Git/中继导入签名事件、获得合格 recipient 的 key grant 并重放出原记录，随后投影为自己的本地句柄：

```dart
final record = replica.service.message(
  actor: replica.service.actor(actorId),
  messageId: authorizedMessageId,
);
final projected = await node.media.project(actorId: actorId, message: record);
final handle = projected.first['data']['file_id'] as String;
final loaded = await node.media.get(actorId: actorId, fileId: handle);
final bytes = base64Decode(loaded['data'] as String);
```

`get` 返回 `{name, mime, size, data}`，`data` 是 Base64。每次读取重新查询原消息/论坛消息/朋友圈可见性与句柄所属主体；知道另一个账号或 bot 的 `file_id` 不会继承权限。投影的 `MessageRecord` 也必须和业务内核存储的原记录完全相符，不能改写 parts 后借原 ID 下载。

论坛 `forum.post` / `forum.reply` 的媒体走论坛 room 范围加密，正文的 forum-thread 消息记录可按相同 `project/get` 读取；朋友圈 `feed.post` / comment 的媒体走 `feed:<作者>:<visibility>`，不能退回全社区控制密钥。private feed 不因另一个账户拥有仓库访问权或文件 hash 就获得读取资格。

## 暂存、范围和 Git

- 上传字节用独立随机 stage key 加密；stage key/句柄索引在本机AEAD加密的 `media-state.enc`，暂存 `.bin` 只有密文。资料目录权限仍需宿主管理，不能整目录 git add。
- 发送时将暂存内容或已授权原消息附件解密，再用目的 scope/当前 epoch 重新加密；得到新的随机 nonce 和密文对象号。相同文件从群聊转发到独立私密范围不能复用原 ciphertext object，避免跨范围关联和错误沿用原 key。
- 原 `file_id`、stage key、`stage:` scope 不进入发送的签名命令参数。签名加密的内容事件只带 `AttachmentRef {scope, epoch, descriptor}`，descriptor 包含密文对象号、原文件名/MIME/大小、明文摘要、nonce/tag；这些描述放在加密正文内，不公开写入 Git 附件分支。
- Git 附件分支为 `refs/heads/attachment/<密文SHA256>`，tree 仅 `object.bin`；附件的钥匙、原文件名和明文描述不在其中。`GitSync` 按需 fetch 精确对象，校验普通 blob、大小和 SHA-256，不 checkout。
- 有 Git transport 时，发布对象必须成功后才让消息事件引用它；发布失败不能报发送成功。历史离线 outbox 后续同步也应先补对象再推设备事件。中继 ack 不证明附件/消息已在对端落盘，Git对象存在也不代表用户有解密权限。
- 密钥授权变化时当前合法成员建立新 epoch/逐 recipient grant；离群者不获得新 key。已合法持有的旧历史与旧 key 无法收回；业务允许的既有历史附件仍可按旧 epoch 读取，不能承诺让过去接收者“忘记”。

`file_id` 本机索引在正常关闭/重启后保持可用；这不代表原 record 被撤销/隐藏或历史资格改变后仍可无条件取回。媒体缓存、outbox、Git pins 的资源上限和清理策略各自独立；不承诺无限历史/磁盘容量。

## 图片处理与限制

默认媒体输入上限 8 MiB，Git密文对象绝对上限 20 MiB；HTTP/WS Base64/body cap 属于 OneBot 适配层，不能因为 Base64 能解析就绕过字节限制。媒体测试不重复负责适配器全部限额测试。

`purpose: 'image'` 通过 core 的 `PreferredImageEncoder` 检查静态 PNG/JPEG/WebP，采用 lossless WebP 输出，MIME 为 `image/webp`、文件名后缀为 `.webp`。这不是任意输入格式/动画/视频/动图支持。像素数、边长、输入输出字节、工作期限等限制由 encoder 实现约束；不是 OS 解码沙箱，也不保证抵御所有原生或纯 Dart 解码器缺陷。

无损在此指解码后 RGBA 保持一致，不等于原压缩容器 bytes 不变，也不意味着 JPEG 源图可以恢复其压缩前信息。透明像素的 RGB 也应被测试比较，不只看画面肉眼相似。

## 本机集成测试

```text
dart test test/media_test.dart --reporter expanded --concurrency 1
```

测试使用 tiny KDF 只加速临时测试账号；生产默认 KDF 未降低。每个 fixture 创建两份真实 `LocalProfile` / `ZaizuoNode` 和本机裸仓库，账号经 root 签名 main 入驻，消息与附件通过真实 Git push/fetch，不使用 mock store/transport。只使用临时目录，无真实账号密码/token、NapCat、公网服务或 SSH 操作。

测试覆盖：

1. 完整 binary 文件 upload → 加密 stage → opaque file_id → scope 重加密 → 先归档对象 → Git同步 → receiver project/get → 完整字节比较；签名正文无 stage key/上传句柄，远端 blob 只为密文；外来主体/其他本地bot/外来 file_id 拒绝；转发私scope更换 object/nonce；重开profile后句柄仍可取。
2. 带透明度和隐藏 RGB 的 RGBA PNG → WebP → 加密附件 → Git → 接收端解码，逐像素比较 RGBA。
3. 离群后不获得新附件 epoch 的 key，也重放不出新消息；原来合法接收的旧历史附件仍可延后下载。
4. 论坛附件和 private feed 使用同一管线、不同scope密文对象；另一个账户拒绝 private feed 投影和句柄读取。

本轮最终冻结源码验证：Dart 3.14.0 / Git for Windows 2.55.0，4/4 全部通过（串行约 8 分钟），测试文件 format 无改动、analyze 无问题。首次并行实施期间曾因 OneBot 中间态括号导致无法 load，后已修复；首次完整运行离群 case 还曾出现一次 Git ls-remote 退出 128，未放宽断言，冻结后单 case 重跑及完整 4 项重跑均通过、未复现。失败时该 case 保留自建临时 fixture 以便定位，成功正常回收；不把不明错误当作成功。

本文件这四项测试只覆盖本机 prototype；Windows/Ubuntu真实SSH双机及分发包的另行验证见[本轮验收](../../docs/图片文件与跨平台验收.md)。弱网、Android后台、断电/磁盘故障、所有OneBot客户端兼容性仍需单独验收。

## 资源与失败边界

- 默认每文件8MiB、索引句柄4096、加密暂存128MiB、本机密文缓存总量256MiB，Git单对象硬上限20MiB；超限拒绝，不自动删除旧历史。
- 发送失败或磁盘保存失败可能保留已加密但未被引用的对象；总缓存扫描会计入它们，不能宣称失败完全不落盘或具备断电原子恢复。未提供自动历史回收工具，不建议手工删未知文件/信任pin。
- 同一MediaRepository会话只缓存已确认成功发布的object ID，以避免每轮重复SSH；重开会重新校验历史outbox，没有把仅尝试过的失败上传记成成功。它不是远端文件永久存在的保证，已知远端删除/改写仍按Git信任规则拒绝。
- 无history.read的post-only bot发送媒体后，其回执投影可能因不具备原消息读取资格而失败；不以放宽下载权限修复此限制。
- `media-state.enc`为本机AEAD加密索引（使用资料存储key）；不是Git分享内容。大于1MiB且小于6MiB的合法索引有保存重开回归；目录仍属于可信本机用户，不是同用户恶意文件系统沙箱。
