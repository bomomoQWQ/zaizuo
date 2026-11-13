# 在座 Android 安装验证壳

这是**最小 Flutter Native 安装/本机图片验证壳，不是正式 IM 页面，也不提供 Android Git、跨电脑通信或完整账号产品**。

- 在 Android `getNoBackupFilesDir()` 下创建专用测试资料，不请求真实账户/密码；本机测试口令和解锁因素都在同一应用私密目录，不能称为 Android Keystore 或独立 2FA。
- 内置自行生成的 64×48 RGBA PNG；也可经系统 `ACTION_OPEN_DOCUMENT` 选择静态 PNG/JPEG/WebP，不申请宽泛存储权限，不持久保存 URI 授权。
- 调用 core `PreferredImageEncoder` 在 isolate 中转为 lossless WebP，再经 `EncryptedAttachments.put/get` 密文落盘、重开读取、解密/摘要对比与错误钥匙拒绝，展示本机解密预览。
- 输入最多 8MiB，最多 4M 像素/4096 边长；不保证压缩后必然更小，不支持动画，也不把 isolate 当 OS 安全沙箱。
- Android Git 明确显示未实现，不尝试 `Process.start('git')`，不把接口 mock 或资料初始化说成真实 Git 同步。
- 所有构建类型都未申请 INTERNET；无公网服务、后台同步或上传逻辑。卸载会清除本机测试资料。
- 页内“关于 / 许可与对应源码”可离线阅读与根 [LICENSE](../../LICENSE) / [NOTICE](../../NOTICE) 逐字节一致的项目许可资产，明确原创代码为 AGPL-3.0-only，并展示/复制 [v0.1.0-media-test3 对应源码](https://github.com/bomomoQWQ/zaizuo/tree/v0.1.0-media-test3)。复制地址不联网、不启动浏览器；第三方原始许可仍由 Flutter 生成的 `NOTICES.Z` 保留并单独展示。此版本为 `0.1.0+2` 的 debug 验证包。

构建工具、debug/internal 签名、安装步骤及本轮验收边界见 [Android构建](../../docs/Android构建.md)。不使用 NapCat 实现或许可证，不代表经过密码学审计。
