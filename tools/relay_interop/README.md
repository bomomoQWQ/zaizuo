# Go / Dart 哑中继 v1：真实进程端点互换测试

这个小项目使用**同一份 Dart 原生 `dart:io.WebSocket` 客户端**，分别连接真实 Go 独立 CLI 和真实 Dart `RelayServer` 子进程，核对 [共享线协议](../../docs/中继协议-v1.md) 与 [共享向量](../../protocol/relay-v1-cases.json)。Dart 包通过 `../../packages/relay_dart` 本地 path dependency 复用。

**这不是两个中继之间的自动互联测试。** v1 没有跨中继桥接/发现功能，脚本不会假设 Go 与 Dart 中继能互相转发。所谓“互通”仅指原生客户端可互换两种实现的端点，获得一致协议行为。

## 运行（Windows / PowerShell）

在仓库根目录执行：

```powershell
.\tools\relay_interop\run.ps1
```

使用已经存在的 `.local/go/bin/go.exe` 与 `.local/dart-sdk/bin/dart.exe`，不安装其他 SDK，不改变系统 PATH，不需要 Docker。若宿主策略拒绝 `.ps1` 执行，不修改或绕过执行策略；可由已有允许的终端入口依次运行下面相同步骤（SDK 命令本身仍须获准）：

```powershell
$root = (Get-Location).Path
$env:PUB_CACHE = "$root\.local\pub-cache"
$env:TEMP = "$root\.local\temp"
$env:TMP = $env:TEMP
$env:APPDATA = "$root\.local\dart-user"
$env:LOCALAPPDATA = $env:APPDATA
$env:DART_SUPPRESS_ANALYTICS = 'true'
New-Item -ItemType Directory -Force "$root\.local\bin", $env:PUB_CACHE, $env:TEMP, $env:APPDATA | Out-Null
& "$root\.local\go\bin\go.exe" build -C "$root\relay-go" -mod=readonly -o "$root\.local\bin\relay-interop.exe" ./cmd/relay
Set-Location tools/relay_interop
& "$root\.local\dart-sdk\bin\dart.exe" pub get
& "$root\.local\dart-sdk\bin\dart.exe" analyze
& "$root\.local\dart-sdk\bin\dart.exe" run bin/run.dart
```

逐步命令请在专用终端运行，退出该终端即可清除这些进程级环境变量；自动脚本会自行恢复。所有命令须成功后再继续下一步。

脚本将：

1. 在 `relay-go` 中执行 `go build -mod=readonly`，将测试 CLI 二进制写到被忽略的 `.local/bin/relay-interop.exe`；不改 Go 源码或模块依赖。
2. 给 Dart 设置仓库内 `PUB_CACHE=.local/pub-cache`、`TEMP/TMP=.local/temp`、`APPDATA/LOCALAPPDATA=.local/dart-user`、`DART_SUPPRESS_ANALYTICS=true`。环境变量在脚本退出时恢复；不删除已有 SDK 或缓存。
3. 在本测试项目执行 `dart pub get`、`dart analyze`、`dart run bin/run.dart`。
4. 启动 Go、Dart 真实子进程，全部只监听 `127.0.0.1`，测试端口从 OS 临时端口取得。不启动公网服务、不修改防火墙。
5. 每个端点测试后终止并等待子进程退出；所有断言失败路径也在 `finally` 中清理。

测试令牌每次由 `Random.secure` 生成，仅通过子进程环境和客户端 Authorization 头传递，不放参数/URL/日志。子进程采用 `ProcessStartMode.inheritStdio`，避免捕获 stdout/stderr 所需的命名管道。Go 可能显示不含令牌的固定启动提示；Dart 测试端点不输出请求内容。

进程准备就绪以本机 `GET /healthz` 的 `200 + ok\n` 为准，最多 15 次指数退避（20 ms 起、封顶 1280 ms），每次 HTTP I/O 有 300 ms 上限；这不是忙等。端口 reservation 释放与 CLI bind 之间有极小竞态，发生冲突将明确失败，不偷偷换公网地址或绕过检查。

## 覆盖范围

每个实现都用相同客户端依次验证：

- ready、压缩未协商；健康端点不暴露状态；缺失/错误/重复 Bearer、任何 Origin、query（含空 `?`）、错误路径与非 GET 的 HTTP 门禁。
- 直接读取共享 JSON 文件的所有正常与异常向量，不在工具里复制另一份协议用例。
- 同主题两个 peer 双向发布/转发、不回发发布者、其他主题隔离、取消订阅幂等、未订阅发布报错；使用响应因果屏障核对未出现额外 event，不靠 sleep 猜测。
- 二进制消息关闭 1003、超大文本关闭 1009。
- 在第一个进程内建立订阅并发布字节后，**停止并重新启动实际进程**（同地址、同端口、同令牌）；新连接从 ready 开始，原订阅不复活，重新订阅后不重放旧事件。这个断言是原型可观察行为，不是对任意未来时刻的数学证明。

payload 是明确命名的 **plain byte fixture**，中继只做 Base64 不透明转发。它没有签名/加密，不可将成功输出解释为已经实现或验证端到端加密。

## 成功输出与限制

当前 Windows 本机已用 Go 1.27.4 / Dart 3.14.0 跑完 `dart analyze` 和连续 10 轮真实进程端点测试，全部通过，1003/1009 均严格核对。验证使用上方直接 SDK 步骤：当前工具宿主拒绝执行 `.ps1`（AuthorizationManager），没有更改或绕过策略；`run.ps1` 只做了 PowerShell AST 语法检查，尚未在允许执行脚本的宿主完整运行。

成功会打印 Go/Dart 各阶段的 `PASS` 和总结果；失败只输出受控场景名或异常类型，不打印收到的任意正文/凭据。返回非零表示构建、分析、启动、协议断言或清理失败。

本工具不替代两端自己的单元/并发/慢连接资源测试；不验证跨中继桥接（不存在）、公网负载、TLS/反代配置、实际聊天客户端、离线补拉、Git、加密、零丢失或持久化。进程停止/重启是测试工具主动杀停的场景，两端优雅 shutdown 另由各自单元与集成测试覆盖。SDK/缓存/测试 binary 保留供重复运行，`run.ps1` 不负责删除它们。
