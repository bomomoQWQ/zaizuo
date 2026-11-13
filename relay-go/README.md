# 在座 · Go 独立哑中继（robust 原型）

模块名 `example.com/zaizuo/relay-go` 是本地标识，不假设已有远端仓库。实现独立编写，WebSocket 使用成熟依赖 `github.com/gorilla/websocket v1.5.3`，HTTP 使用 Go 标准库 `net/http`，不复制 NapCat 代码或许可证。本项目原创代码采用 [AGPL-3.0-only](../LICENSE)，见[版权及第三方声明](../NOTICE)；gorilla/websocket等依赖保留其各自许可证。

遵循 [哑中继协议 v1](../docs/中继协议-v1.md)，测试直接读取 [共享向量](../protocol/relay-v1-cases.json)。本组件不是账号系统、聊天历史库或加密 SDK。

## 能做什么，不能保证什么

- 只校验本地连接令牌、维护**内存中的连接表、订阅表和有限发送队列**，转发不透明 payload；不解密、不解析内部信封、不写正文日志、不持久化数据。
- 不是“无状态”：进程重启会丢失全部临时状态。不会保存离线消息、重放、去重、跨连接排序、Git 记录或 Git 凭据；不做 NAT、自动选主、自动互联或 OneBot 投影。
- 同连接按接收顺序处理，按主题给其他订阅连接转发，**不回发发布连接**。同账号的其他连接仍可收到，中继没有账号概念。
- `publish` 的 `ok` 仅表示中继处理了该消息；**不是收件人送达、落盘或 Git 提交保证**。队列满、网络故障和服务退出均可能丢失事件。客户端负责签名/加密、事件去重与经 Git 补齐缺口。
- 共享连接令牌不是会话授权边界。知道令牌和路由标签即可订阅；真正内容隔离依靠客户端端到端加密。仅传 Base64 示例不证明已经实现加密。中继仍能看到 IP、标签、流量与时间元数据。

## 本机运行

需要 Go 1.22+。仓库若提供便携 SDK，直接调用它，不修改系统 PATH，例如 PowerShell：

```powershell
Set-Location relay-go
# 令牌从你自己的安全环境注入；不要在命令行参数、URL、日志或公开脚本中写真实值。
& ..\.local\go\bin\go.exe run ./cmd/relay
```

启动必须有 `ZAIZUO_RELAY_TOKEN` 环境变量：32～256 个 ASCII 可打印、非空白字符（`0x21..0x7e`），未配置或非法即报错退出，**先验证再监听**。默认仅监听 `127.0.0.1:8787`，默认 HTTP 只用于本机。

也可由受保护的本地文件只读加载：

```powershell
& ..\.local\go\bin\go.exe run ./cmd/relay -token-file C:\private\zaizuo-relay.token
```

`-token-file` 显式优先于环境变量，不可读/非法不回退；只允许文件尾可选的一次 LF 或 CRLF，其他空白均拒绝。程序不创建、不修改、不回显令牌文件，也没有 `-token` 参数。请自行限制文件读取权限；其他进程可读到同用户环境/文件是系统安全边界。日志只含固定启动/错误提示，不含请求正文、令牌、文件路径或客户端输入。

所有资源限制均有 CLI 参数，`-h` 可查看。`-listen` 可显式覆盖监听地址；**这不会自动提供 TLS**。Ctrl+C / SIGTERM 会同时停止 HTTP 接入并关闭所有升级后的 WebSocket，不能只调用 HTTP shutdown。

## HTTP / WebSocket

- `GET /healthz` → `ok\n`，无凭据，不暴露连接/主题数据；不接受 query。
- `GET /v1/ws`，必须 `Authorization: Bearer <token>`，无 query（包括空 `?`）、**完全没有 `Origin` 头**（即便空值也拒绝）。不支持浏览器，原生 Go/Dart/Flutter 客户端可用。
- 错路径 404、非 GET 405、query 400、Origin 403、未授权/重复 Authorization 401、非 WebSocket 升级 400、额满/停止中 503。Bearer scheme 大小写不敏感；令牌本身逐字节匹配，用 SHA-256 固定长摘要与常时比较，不早停比较原令牌。
- 禁用 WebSocket 压缩。仅接受文本消息，一个消息一个 JSON 对象；`ready`、请求、响应与字段以协议为准。请求字段严格校验类型、白名单、ID、64 位小写十六进制 topic、规范标准 Base64；JSON null 不能冒充字符串，不能有尾随 JSON。重复键按协议属于未定义格式，发送者禁止生成，中继不以字段内容作账号授权决策。
- `subscribe` / `unsubscribe` 幂等；先订阅才可发布。这是资源规则而非聊天授权。

示例（仅协议字节，不是完整加密事件）：

```json
{"op":"subscribe","request_id":"s1","topic":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
{"op":"publish","request_id":"p1","topic":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","payload":"AQID"}
```

## 资源上限与关闭行为

与协议默认一致；公开配置中每项必须为正数，可从 `DefaultConfig(token)` 开始覆盖。`MaxPayloadBytes` / `-max-payload-bytes` 仅可下调，不能超过 v1 的 32768 字节硬上限：

| 项目 | 默认 | CLI 参数 |
|---|---|---|
| 总连接（含进行中的已接纳升级） | 128 | `-max-connections` |
| 单连接订阅数 | 64 | `-max-topics` |
| 整条文本消息 UTF-8 字节数（含分片） | 65536 | `-max-message-bytes` |
| payload 解码字节数 | 32768 | `-max-payload-bytes` |
| 每连接待发队列 | 32 条 | `-queue-capacity` |
| 固定窗口请求数（含无效 JSON 等错误请求） | 100 / 10 秒 | `-max-requests` / `-rate-window` |
| ping 间隔 | 30 秒 | `-ping-interval` |
| 写入/关闭控制帧宽限 | 5 秒 | `-write-timeout` |

每连接单独 writer，广播只做非阻塞入队，不等收件人网络 I/O，也不在网络写入时持有全局路由锁。队列满或写失败/超时关闭 1013 并立即移除订阅；其他连接继续工作。二进制 1003、消息过大 1009、请求速率超限 1008、服务停止 1001。关闭时未发送队列会丢弃；网络已完全卡死时 1013 控制帧本身也可能无法送到对端，因此客户端可能只观察到断线。

消息超限后不继续解析或接收应用请求；发送 1009 后，在同一个关闭期限内尝试 TCP 写半关闭，并最多丢弃 128 KiB 剩余原始输入，以降低未读 TCP 数据触发 reset、遮蔽关闭码的风险。恶意无限发送者仍受字节数和绝对 deadline 双重限制，不为保住关闭码无限排空网络。极端网络故障或远超排空上限时仍可能只观察到断线。

服务定时 ping，收到 pong 延长读期限到两个心跳周期。默认失活宽限约 60 秒，Dart 库自身心跳关闭时点不必相同。普通应用消息不冒充 pong。CLI 的整体退出宽限是两个写入宽限，超时强制关闭；没有无限等待用户读取队列。

## 嵌入 `net/http` / 测试

```go
cfg := relay.DefaultConfig(token) // import relay "example.com/zaizuo/relay-go"
h, err := relay.New(cfg)
if err != nil { return err }
server := &http.Server{Addr: "127.0.0.1:8787", Handler: h}
// 运行 server.ListenAndServe()；退出时两者都要调用：
ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
defer cancel()
_ = h.Shutdown(ctx) // 关闭所有 WS，并拒绝新升级
_ = server.Shutdown(ctx) // net/http 本身不会关闭 hijacked WS
```

公开入口是 `Config`、`DefaultConfig`、`ValidateToken`、`New`、实现 `http.Handler` 的 `Server` 和 `Shutdown(context.Context)`。构造后不会保留配置中的原始 token，仅保留固定长摘要。嵌入方负责 HTTP header 超时、header 大小限制、日志策略和 HTTP 监听生命周期；CLI 已配置 header 超时及 16 KiB header 上限。

## TLS / 反向代理 / Docker

跨主机必须使用 TLS/WSS 或可信加密组网，**不要公网裸 WS 传共享令牌**。推荐 TLS 反向代理和中继处于同主机/受保护内部网络，中继保持本机 HTTP：

```nginx
# 放在已正确配置证书的 HTTPS server 内；此处不包含证书配置。
location = /v1/ws {
    proxy_pass http://127.0.0.1:8787;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Authorization $http_authorization;
    proxy_read_timeout 90s;
    proxy_send_timeout 90s;
    proxy_buffering off;
}
```

代理应保留客户端 Origin，让后端拒绝浏览器来源；**不要主动清除 Origin 来绕过校验**，也不要把 Authorization 或 query 记入访问日志。TLS 终止后的网络链路也必须可信。客户端仍传 Header Bearer，不在 URL 里放 token。

在本目录构建镜像（不需要整个仓库作 build context）：

```text
docker build -t zaizuo-relay:local .
docker run --rm --read-only --cap-drop ALL --security-opt no-new-privileges \
  -p 127.0.0.1:8787:8787 --env ZAIZUO_RELAY_TOKEN \
  zaizuo-relay:local -listen 0.0.0.0:8787
```

示例是 POSIX shell 换行形式，PowerShell 可写为一行；`--env ZAIZUO_RELAY_TOKEN` 从宿主已注入环境取值，不在命令里写真实值。镜像以非 root、scratch 运行，默认仍仅监听容器本机，所以容器端口映射需显式 `-listen`；宿主示例只发布到 loopback，再由 TLS 代理向跨主机客户端提供 WSS。也可只读挂载令牌文件并传 `-token-file /run/secrets/relay-token`（文件须让 UID 65532 可读）。镜像/程序不需要可写数据卷。

## 验证与测试边界

从本目录运行：

```text
go mod download
gofmt -w .
go test ./...
go test -race ./...
go vet ./...
```

`-race` 在 Windows 需要支持的 C 编译器和 CGO；若缺失，普通测试通过不等于通过 race 检查。便携 SDK 可用完整路径代替 `go`，无需另装多份工具链。

测试包含：共享正常/异常向量；严格 JSON/Base64/大小边界；HTTP 授权/Origin/query；禁压缩/连接与订阅上限；二进制/超大消息/速率关闭码；分主题不回发自己、unsubscribe 幂等；全 WS shutdown；ping/pong/失活；并发发布；基于 channel 门控 transport 的慢连接满队列隔离、1013 写失败与强制 shutdown。集成测试使用 `httptest` 的本机环回监听，全部为虚假测试令牌。

慢连接核心测试不依赖 sleep 或特定 OS TCP 缓冲大小；心跳测试等待实际 ping 事件并设置总期限。测试不能证明公网负载、所有反代配置、实际客户端加密、移动网络断线恢复或零丢失，也未替代部署环境的 TLS/权限/容量审查。Docker 构建、反代 TLS 和容器运行需要额外环境验证。
