# zaizuo_git_mobile：嵌入式 Git 后端

本包把 exact `git2dart 0.5.6` + `git2dart_binaries 1.14.1` 的 libgit2 包装为 core 的 `GitBackend`；不在 Android 上启动系统 git 可执行文件。原创代码按项目 AGPL-3.0-only，第三方分别保留原许可；[原生来源与许可清单](<../../third_party/native_git/SOURCES.md>) 明确尚未闭环的供应链事项。

## API 与调用边界

在主 Flutter isolate 上准备 CA（Android 使用 `EmbeddedGitBackend.initializeAndroidCertificates()` 提取包内 PEM），然后为每个同步实例建立独占 backend：

```dart
final caPath = await EmbeddedGitBackend.initializeAndroidCertificates();
final backend = EmbeddedGitBackend(
  bundledCaPath: caPath,
  credential: GitHttpsCredential(
    repositoryUrl: repositoryUrl,
    username: username,
    personalAccessToken: personalAccessToken,
  ),
);
final sync = await GitSync.initializeWithBackend(
  backend: backend,
  worktree: appPrivateWorktree,
  remoteUrl: repositoryUrl,
  deviceId: deviceId, // 64 位小写十六进制
);
```

`GitSync.initializeWithBackend` 是 **core API**；本包提供 `EmbeddedGitBackend` 与 `GitHttpsCredential`。示例变量须由调用者提供，不要把真实 PAT 写入源码或日志。`credential` 可省略用于匿名 HTTPS。凭据绑定精确 repository URL，不接受 URL 内嵌用户名/PAT。

- 生产远端仅允许 **HTTPS**，不支持 SSH、git:// 或生产本地裸仓库。即使预构建 SO 依赖 libssh2，也不代表本应用开放 SSH。Android `libgit2.so` 实际 DT_NEEDED 包含 `libssh2.so`，不能因应用禁用 SSH 就随意从包里删库。
- `EmbeddedGitBackend.testLocalBare` **仅用于隔离测试**；不作为生产配置、失败回退或 TLS 旁路。
- `bundledCaPath` 须为本机绝对 PEM 路径。Android 使用捆绑 CA，不是 Android/操作系统系统信任库；用户安装 CA 和浏览器的全部信任约束不自动继承。不得通过关闭证书校验来“修复”连接。
- 后端要求 libgit2 HTTPS backend=`openssl` 才能严格绑定独立 CA。当前 Windows 锁包 libgit2=1.9.7，实际 HTTPS backend=`winhttp`，生产 HTTPS 路径按 `unsupported_tls_backend` **fail closed**；这不是 Windows HTTPS 已可用。Windows 本地 primitive 测试通过也不改变此边界。
- 同一 worker 首次成功 HTTPS 初始化后，CA **原始字节内容固定**；其他仓库可复用同 CA（不同路径同内容可接受），不同内容按 `ca_policy_change_required` 拒绝。不能把反复调用全局 libgit2 CA setter 当作隔离的每仓库信任策略：OpenSSL store 可能累积此前 CA。更新信任需重启进程；首次 setter 失败会隔离该 worker，禁止用可能部分初始化的 store 继续。该限制也防止多个仓库间信任污染。
- 首次 worker 必须从 root Flutter isolate 启动；单一 root-owned 常驻 worker 对本进程各 backend 的原生操作全局串行。子 isolate 必须使用主 isolate 提供的 `workerPort` 和 `EmbeddedGitBackend.connect(workerPort:, bundledCaPath:, credential:)`，不能各自独立启动工人或绕开全局 libgit2 配置串行化。
- 每个 backend 只绑定一个 `GitSync`，不能跨同步实例共享；只使用应用私有目录中的专用仓库，不接管用户目录、共享存储、外部 Git 仓库。调用者负责选择 app-private worktree 与凭据/CA 路径。

## 资源与安全限制

- PAT 是 Dart String，调用/worker 传递会产生托管内存副本；日志隐藏不等于内存清零，**没有可靠 zeroize 保证**。调用方负责最小权限令牌、撤销/轮换和安全存储；不要使用真实账户做默认测试。
- worker 常驻进程，关闭单个 backend 不等于结束 worker。原生操作串行也意味着一个耗时 fetch 会阻塞其他调用。
- `maxBlobBytes` 是对象读取上限，不是 fetch pack 上限；当前没有 fetch pack 总下载预算或整个 worker/native 操作的总时间预算。不得宣称能安全处理任意不可信巨大仓库或无限资源输入。
- 应用只接受其管理的数据/目录边界；不是通用 Git 客户端、安全沙箱或完整端到端安全证明。

## 证据与测试范围

Windows native interop 5 项 + primitive 3 项通过；不扩大成 Windows HTTPS 成功。Ubuntu 24.04 的同锁包 libgit2 1.9.7/OpenSSL 路径已跑真实 loopback TLS smart-Git：6 项通过（认证二进制推拉+CLI oracle、错误/缺凭据、错主机名、固定 CA 策略、重定向拒绝、非FF拒绝，以及独立新进程的未知 CA 握手拒绝）。测试服务支持有界 chunked 请求，不关闭证书校验、不安装系统 CA。当前真实 Android 设备数为 0，**未验证真实 Android HTTPS/ABI运行**；桌面 native 网络证据不能代替手机测试。

[缓存原生文件清单](<../../third_party/native_git/native-manifest.json>) 覆盖 Android 四 ABI 每个 libgit2/libssh2/libssl/libcrypto 及 Windows 四 DLL；20 个文件 SHA/size 与包装包 sidecar 匹配。Android 字符串 `libssh2_1.11.1_DEV` 与 sidecar 声称版本之间的源码身份缺口仍保留。版本、完整许可与对应源码交付缺口见 [SOURCES](<../../third_party/native_git/SOURCES.md>)；当前不是完整 release 合规放行。

许可资产由应用父任务复制/声明；本包 README 或 Flutter 自动 license registry 不能替代 APK 内的 native 全文与最终 APK 清点。本轮未构建、未修改 pubcache、未推送 release。
