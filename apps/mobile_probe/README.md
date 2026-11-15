# 在座简版测试客户端

## 当前前端（0.1.0+4）

默认入口现为简版聊天页面：创建/解锁账户、空间与私聊、文字/图片、公开社区加入与接纳、Git 手动同步和状态。桌面宽屏与手机窄屏使用同一界面；原开发探针在“关于”入口保留。操作及测试边界见 [测试前端](../../docs/测试前端.md)。Windows/Linux 平台宿主已生成；Windows Release 已构建并以普通权限启动核对欢迎界面，Linux 本轮未构建。Windows 首轮插件链接由维护者明确授权的单次管理员构建准备，不改变日常运行权限或系统安全策略。Android arm64 为内部 debug 测试包，真机验收仍待进行。

以下内容描述保留的开发工具，不代表默认聊天页面所有按钮布局。

这是**Flutter Native 图片与前台手动 Git 开发验证壳，不是正式 IM 页面或完整账号产品**。本轮新增内嵌 libgit2 的真实 Git 后端与 Android 接线；构建成功、桌面互通测试和手机实际联网验收是三类不同证据，不能混为一谈。

- 在 Android `getNoBackupFilesDir()` 下创建专用测试资料，不请求真实账户/密码；本机测试口令和解锁因素都在同一应用私密目录，不能称为 Android Keystore 或独立 2FA。
- 内置自行生成的 64×48 RGBA PNG；也可经系统 `ACTION_OPEN_DOCUMENT` 选择静态 PNG/JPEG/WebP，不申请宽泛存储权限，不持久保存 URI 授权。
- 调用 core `PreferredImageEncoder` 在 isolate 中转为 lossless WebP，再经 `EncryptedAttachments.put/get` 密文落盘、重开读取、解密/摘要对比与错误钥匙拒绝，展示本机解密预览。
- 输入最多 8MiB，最多 4M 像素/4096 边长；不保证压缩后必然更小，不支持动画，也不把 isolate 当 OS 安全沙箱。
- Git 使用 [git_mobile](../../packages/git_mobile/README.md) 的 `EmbeddedGitBackend`，不会启动手机系统 Git。签名名册、原始设备事件链、不可变附件及本地 pins 共用 core 的验证逻辑，不复制一份移动端安全协议。
- 仅 HTTPS + 显式用户名/PAT，禁 URL 内凭据、SSH、重定向及信任所有证书。CA 来自锁包的捆绑根，不等同 Android 系统信任。PAT 由非导出 Android Keystore AES-GCM 密钥包裹后存 noBackup 目录；账号测试因素仍与资料同目录，两者不能混称独立账号 2FA。
- 主 manifest 仅新增 INTERNET；仍禁备份/明文流量，无宽泛存储权限、公网监听、后台常驻或自动同步。只有用户点前台操作才访问指定仓库；保存凭据不表示已经同步成功。
- 操作次序：A 新建独立测试资料（或首次导入公开名册+仓库外核对的根指纹）→导出公开名册/加入请求，由根账户接纳→输入专用测试仓库 HTTPS 与最小权限 PAT 并保存→B 打开节点→C 手动同步→D/E 写测试消息/图片→再次 C。不要用本项目公开源码仓库充当聊天传输仓库。
- 页内许可离线保留根 [LICENSE](../../LICENSE) / [NOTICE](../../NOTICE)、Flutter notices 和 [原生依赖来源及已知缺口](../../third_party/native_git/SOURCES.md)。当前 `0.1.0+3` 是**未发布开发构建**；移动的 main 地址不是固定对应源码证明，不覆盖旧 test3 Release，也不宣称本轮已发布新包。
- 真机尚未连接：Keystore 保存/重开、ABI 装载、Android HTTPS 网络、生命周期与实际双机收发仍需设备验收。测试 profile 只能使用丢弃式数据，非生产密码学审计结论。

构建工具、debug/internal 签名、安装步骤及本轮验收边界见 [Android构建](../../docs/Android构建.md)。不使用 NapCat 实现或许可证，不代表经过密码学审计。
