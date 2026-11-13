# zaizuo_relay：在座 Dart 哑中继原型

独立纯 Dart 包，SDK `>=3.6.0 <4.0.0`，使用 `dart:io HttpServer`、原生 `WebSocket` 与 `crypto`。无 Flutter UI、无框架、无 Dart workspace 配置；可嵌入 Flutter Native（Windows / Linux / Android），不适用于 Flutter Web。

遵循 [哑中继协议 v1](../../docs/中继协议-v1.md)。这是**通信原型，不是业务加密实现**；payload 只是经过严格 Base64 校验的不透明字节，中继不解密或解析其内部字段。连接令牌不是账号认证或会话授权边界。无存储、历史、排序、去重、Git、OneBot、NAT 穿透或自动发现。

## 嵌入宿主

```dart
import 'package:zaizuo_relay/zaizuo_relay.dart';

final config = RelayConfig(token: localSecret); // 32–256 个可打印非空白 ASCII
final server = await RelayServer.start(config); // 默认 127.0.0.1，端口 0
final actualPort = server.port;
// 宿主/Flutter Native 生命周期结束时：
await server.close(); // 幂等，关闭监听及所有已建立的 WebSocket
```

`RelayServer.start(config, {InternetAddress? address, int port = 0})` 默认仅本机 IPv4 环回。跨主机监听必须由宿主显式提供 `address`，且部署 TLS/WSS 或可信加密组网；本包不会替宿主配置 TLS，不要在公网裸 WS 中发送共享令牌。Android 宿主还需自行配置网络权限与生命周期。

[example/main.dart](example/main.dart) 只是通过环境变量读取令牌、启动服务、按 Enter 停止的 CLI 演示，不是主要运行模式或公网部署器：

```powershell
$env:ZAIZUO_RELAY_TOKEN = 'only-a-local-example-token-32-characters'
dart run example/main.dart
```

库不输出日志，错误不回显凭据、URI、正文或任意输入字符串。示例只打印端口和固定提示。宿主仍需避免记录 Authorization 头，且不要在 URL、命令行参数或版本库中放真实令牌。

## 入口与协议

- `GET /healthz`：无需鉴权，正文仅 `ok\n`。
- `GET /v1/ws`：只接受无 query（连空 `?` 也拒绝）的原生 WebSocket 升级。只从单个 `Authorization: Bearer <token>` 读取令牌；Bearer scheme 大小写不敏感，token 大小写敏感。任何 Origin 头（含空值）都返回 403。
- 未授权 401、错误路径 404、非 GET 405、query/无效升级 400、达到连接上限 503。不接受 token URL 参数。禁用压缩。
- ready、subscribe、unsubscribe、publish、ok、event、error 的字段完全遵循 v1。严格检查 JSON 对象、字段集合、类型、标识、规范带 padding 标准 Base64（包括 pad bits），未知操作是 `unsupported_op`。重复 JSON 键按协议属于未定义格式，不用于业务安全判断。
- 发布前必须订阅；转发只送给该 topic 的其他连接，不回送同一发布连接。取消/订阅幂等，按本连接输入顺序处理。不同连接之间无全序。
- `publish` 的 `ok` 只代表中继处理该请求，**不是任何收件人的接收、写盘或持久化回执**。慢连接断线后仍需客户端去重和 Git 补齐。
- token 用同一随机本地密钥派生为固定 32 字节 HMAC-SHA256，再完整异或比较摘要，无提前退出的 token 字符串比较；这不是对 VM/JIT、整个 HTTP 流程的常数时间保证。无效 token 长度/字符和错误头格式会提前拒绝。

## 有限资源与背压

`RelayConfig` 各上限必须为正数，默认：

| 字段 | 默认 |
| --- | --- |
| `maxConnections` | 128（包括升级中和关闭中的连接） |
| `maxTopicsPerConnection` | 64 |
| `maxMessageBytes` | 65536（完整文本 UTF-8 字节数） |
| `maxPayloadBytes` | 32768（允许下调，不能超过 v1 硬上限） |
| `maxPendingMessages` | 32（包含正在发送的一条、ready 和所有响应/event） |
| `maxRequestsPerWindow` | 100（固定 10 秒窗口，含错误文本请求） |
| `pingInterval` | 30 秒 |
| `writeTimeout` | 5 秒（写入与主动关闭宽限） |

队列不是装饰开关：每连接有有限 FIFO，始终只允许一条应用消息在途；写入须等真实 Socket 的 `flush()` 完成才从队列取走。底层流的暂停向上传播，不把队列无限排进 `WebSocket.add`/IOSink；flush 等待期间也暂停原始入站流，避免不断读取 ping 并给堵塞输出无限排 pong（已在当前原生读取块中解析的控制帧仍有 SDK 缓冲边界）。容量满或写超时独立关闭慢连接 1013，不等待或阻塞其他收件人。速率超限 1008，完整文本过大 1009，任何二进制消息 1003。WS `pingInterval` 使用 Dart 库语义，按其一个周期内未收到 pong 关闭；关闭时点不保证与 Go 毫秒级一致。

为可取消阻塞写入和可测背压，升级后保留原始 Socket，用一个小型 Socket 包装器把 SDK 输出串行 `add` / `flush`。WebSocket 仍由 Dart SDK 负责入站解析、mask、分片、UTF-8、控制帧和 ping/pong；本包不重造入站 WS parser。包装器只追踪**出站头部**确定 flush 边界，最多保留 10 字节头部。Dart 部分 SDK 的 `WebSocket.close` 把已分配的 1013 仍当保留码，因此只将 SDK 输出 close payload 的两个状态码字节替换为 1013；无业务 payload 改写。若 TCP 已堵死，关闭帧也可能无法送达，宽限结束会 `destroy()`，对端可能只看到异常断线，不能承诺必收到 1013。

### 原生流帧/内存边界（重要）

Dart `WebSocket` 通常在交给应用前，已经在 SDK 内组装完整消息（可能包含很多 continuation 帧）。本包在**收到完整消息后、JSON 解析前**检查 UTF-8 大小，避免接受/转发超限数据，但这不能阻止 SDK 先分配大消息，也不能在所有支持的 SDK 上从公开 API 完全限制原生流帧层。长度先用 UTF-16 单元数做低成本下界检查，再在必要时计算 UTF-8；这仍可能产生一次有限/超限消息副本。二进制也可能先组装再按 1003 拒绝。

因此本包**不承诺恶意对端不耗内存、不承诺接收侧总 RSS 硬上限**。有限应用队列不等于 OS/SDK 缓冲为零；`flush()` 也不等于远端应用收到。HTTP 层的半开/超大头部/预升级连接还受 Dart HTTP 栈与部署入口约束，不计作已经接入的 WS 连接。若需要不可信公网对端的逐帧和总内存硬隔离，应在受控入口/进程资源限制下运行，或使用提供底层流限制的独立中继，不把此原型当作 DoS 防护承诺。

## 本地验证

在此目录独立运行（不要在仓库根依赖 Dart workspace）：

```powershell
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze
dart test
```

测试只监听 `127.0.0.1`、只用虚构令牌。共享向量直接读取 [protocol/relay-v1-cases.json](../../protocol/relay-v1-cases.json)，不复制一份。纯解析、固定窗口、有限队列和出站头处理使用同步状态/Completer；集成测试用响应屏障而非靠硬 sleep 判定未转发。少量实际超时分支使用短 Timer，测试不代表公网大规模吞吐、安全审计或 Flutter 三端实机验证。

本轮实跑 Windows x64 Dart **3.14.0**：format 检查 13 个 Dart 文件无变更、analyze 无问题、113 项测试通过。曾验证最新允许的 crypto 3.0.8 / test 1.33.0，也验证最低直接依赖 crypto 3.0.6 / test 1.25.15（传递依赖由当前 SDK 正常解析）。全量 `pub downgrade` 会选到不兼容新 Dart 的历史传递测试工具，不作为本包支持承诺。作为独立库不提交 lock；旧 SDK 需在本包目录重新 `pub get` 选择兼容版本。**Dart 3.6、Linux/Android、Flutter Native 实机、真实网络慢 TCP/RSS 压测未实跑**。背压测试使用可控 Socket.flush 阻塞以免用不稳定的大流量/硬 sleep 假装证明；真实坏链路仍可能只出现异常关闭。

本项目原创代码采用 [AGPL-3.0-only](../../LICENSE)，见[项目声明](../../NOTICE)；第三方依赖保留各自许可证。不包含/复制 NapCat 实现、二进制或许可证。
