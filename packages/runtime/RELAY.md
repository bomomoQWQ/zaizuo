# 加密日志的本机中继链路（原型）

[relay_client.dart](lib/src/relay_client.dart) 把应用已有的 `FileEventStore` 与 [中继 v1](../../docs/中继协议-v1.md) 连通。可对接相同线协议的 Dart/Go 中继；本轮自动化测试实际运行 Dart 中继，不把线协议兼容设计说成已经完成 Go↔Dart 互通实测。

这不是业务解密器、自动授权器或另一份日志。中继依然不验事件签名；**客户端**收到后经 `TrustStore.verifyEvent` 与 `store.import` 验证并落盘。业务命令解密和权限投影由宿主显式提供的 `onImported` 回调触发，例如 `replica.refresh()`。

## API 与接入

```dart
import 'package:zaizuo_runtime/src/relay_client.dart';

final topic = await relayTopic(
  communityId: store.trust.communityId,
  conversationId: conversationId,
);
final link = await RelayLink.connect(
  // 缺省 ws://127.0.0.1:8787/v1/ws，必须是数字环回地址。
  url: Uri.parse('ws://127.0.0.1:8787/v1/ws'),
  token: localRelayToken,
  store: store,
  topics: {topic},
  onImported: (_) => replica.refresh(),
);

// 先本地加密写盘，后把同一个原始信封送中继；不要为每条通道重新加密。
final event = await store.append(device: device, key: key, body: commandBody);
try {
  final ack = await link.publish(event);
  assert(ack.relayAccepted && !ack.remoteDurable);
} on RelayLinkException catch (error) {
  // error.code 为固定安全码；error.requiresGit 始终为 true。
  // 已有本地日志仍是事实来源，经正常 Git 同步补齐，不宣称零丢失。
}

// 应在关闭 replica/store 之前关闭链路。
await link.close();
```

- `connect` 等到 `ready(version=1)` 和所有 `subscribe` 的正确 `ok` 才返回；不是仅创建 socket 就认为成功。
- `publish` 只接受本 `store.allEnvelopes` 中同 ID、完整 canonical 信封一致的已落盘事件。只序列化原密文信封并标准 Base64，不解析/重加密业务正文。信封 UTF-8 超过 32768 字节明确抛 `envelope_too_large`，需走 Git，不截断。
- 信封里的社区必须与本 store 一致，路由 topic 必须已订阅。接收方也重新计算路由，防把另一会话信封塞进订阅通道。
- topic 是带域分隔、社区和会话两个独立 canonical 字段的 SHA-256（64 小写 hex），不含密钥或明文房间名。它不是密钥，也不提供“已知名称不可猜测”保证；中继仍看得到流量、时间、路由标签等元数据。不要把 topic/令牌视为会话授权。
- `onImported` 仅在新的信封 `store.import` 完成（包含 flush）后调用；重复事件不重复回调。乱序信封可能仅持久化为 pending，或被链索引隔离，回调应使用完整索引重放，不能把单一信封当已通过业务授权。
- **设备序号链横跨所有会话**。只订阅部分 topic 时，其他 topic 的前驱可能缺失，实时事件会保持 pending；必须经 Git 补齐完整设备密文链才能接纳/投影。此链路不跳号、不自动订阅未授权会话，也不承诺“收到了这一个 topic 就必能实时显示”。
- `RelayPublishAck` **只表示中继处理 publish**，不是远端接收、验签、写盘、Git 或业务成功回执。`remoteDurable` 明确为 false。无人订阅时也可能收到 ok。

## 断线、队列与生命周期

默认每次请求超时 5 秒，重连延迟 1 秒，原生 pingInterval 30 秒；`maxPendingPublishes=32`、`maxPendingImports=32`，包括正在处理项。每连接同时只有一条待 ack 的请求，避免把有限发布队列无限排进 SDK 输出缓存。队满明确拒绝，不悄悄丢弃并返回成功。

`states` 提供 connecting / connected / disconnected / closed；当前状态可读 `state` / `isConnected`。`errors` 只提供固定 `RelayLinkException`，无令牌、URL、正文或任意底层错误文本。库不输出日志。

建立之后默认自动重连并重新订阅；首次连接失败直接返回错误，由宿主决定是否重试。待 ack 的发布遇到超时/断线全部返回 `requiresGit=true`，不自动重发，因为它可能已经被转发而只是 ack 丢失。补齐以持久日志和事件 ID 去重为准，不能承诺 exactly-once 或零丢失。可设置 `autoReconnect=false`。

`close()` 幂等，取消重连/请求计时器、销毁 socket、清理队列；等待已开始的 `store.import` 完成后才返回，避免宿主随后关闭 store 时仍有隐藏写入。宿主回调有请求超时限制，但 Dart Future 不能被强制取消：超时的宿主回调自身仍可能继续，需宿主自行保证其生命周期和取消语义。链路不拥有、不会关闭 store/replica。

## 网络和安全限制

**本轮只接受 `ws://` 数字 loopback（IPv4/IPv6）和精确 `/v1/ws`，不接受 `localhost`/DNS、非环回地址、userinfo、query、fragment 或 WSS。默认端口 8787。** 这是有意受限，不是可直接公开部署的 TLS 客户端。跨网生产接入必须另做 WSS/证书/入口安全设计，不能将共享 Bearer 放裸 WS 公网传输。

不使用会自动跟随重定向的 `WebSocket.connect`：用 `HttpClient` 明确 `followRedirects=false`、代理 DIRECT，验证标准升级响应与 accept，随后交 `WebSocket.fromUpgradedSocket`。不会把 Bearer 转发到 `Location` 目标；不依赖源地址是环回就放任重定向。压缩不启用。

Dart 原生 WebSocket 仍可能在交给应用之前组装完整消息；本模块在完整消息后限制 65536 字节，再在 Base64 解码后限制信封 32768 字节。不承诺底层帧内存/RSS 硬上限，也不宣称本机端口能抵挡不可信本机进程 DoS。入站队列有界；慢磁盘/慢回调达到上限会断线并靠 Git 补齐。签名只能证明持有签名密钥和受信设备链，不等于业务权限；业务权限仍由 replica/domain 判定。本轮不是密码学审计。

## 测试范围

[relay_client_test.dart](test/relay_client_test.dart) 使用虚构令牌、数字环回监听、真实 `RelayServer.start` 和两个受信文件日志：原信封转发、接收 flush/重开/解密、坏签名和错误会话路由不落盘、超大/未持久/错误 topic 拒绝、断线回落、重连订阅、订阅 ack 屏障、重复幂等、阻塞回调的有限导入队列、close 生命周期、队满/ack 超时和拒重定向凭据泄露。用响应/Completer/状态屏障而非硬 sleep；计时器只验证真实超时与重连逻辑。本轮 Windows x64 Dart 3.14.0 下定向 **12 项全过**，新文件 analyze 无问题；添加后全 runtime **35 项通过**（含真实 Git/OneBot 集成），不把本机测试当公网压测、全平台或 Go 互通证明。
