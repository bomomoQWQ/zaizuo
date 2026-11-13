# 在座 CLI 便携测试包

这是「在座」非界面原型，不是聊天图形界面、Flutter安装包或Android APK，不是QQ/微信客户端，也不包含NapCat代码。项目许可证待用户决定，当前仅用于用户授权的本地/内部验收；不要自行公开发布或推送。

## 包内容和平台

- Windows `snapshot` 包：`zaizuo.cmd` + `bin/dartaotruntime.exe` + `bin/zaizuo.aot`。这是**AOT快照与配套运行时**，不是单文件在座EXE；最终用户无需安装Dart SDK。
- Windows `exe` 包：仅标准 `dart compile exe` 成功后才生成的原生可执行文件与启动器，不会把失败的snapshot冒充单文件exe。
- Linux包：`zaizuo` 启动器 + `bin/zaizuo` 原生CLI，按构建机x64/arm64架构，不能跨架构混用。
- `BUILD.json`（构建类型/版本）、`SHA256SUMS`（包内文件摘要）、`licenses/`（Dart与依赖许可证/锁定清单）、`runtime.env.example`（**不含秘密**的设置说明）。
- 不附Dart完整SDK、Git、cwebp、真实账户/口令/令牌/设备资料、社区仓库或缓存。不安装系统服务，不修改PATH、防火墙或开机启动。

## 先验证再运行

Windows在PowerShell里进入解压目录：

```powershell
# 对照外层.zip.sha256；摘要只能检验完整性，不代替可信分发签名。
Get-FileHash -Algorithm SHA256 .\zaizuo-cli-*.zip
# 解压之后，在包目录：
.\zaizuo.cmd --help
```

Linux在包目录：

```sh
sha256sum -c SHA256SUMS
./zaizuo --help
```

Windows解压到自己有写权限的目录，无需管理员；不要关闭SmartScreen/杀毒/执行策略以运行。Linux便携包无需root；若系统安全策略禁止执行，先报告具体原因，不要擅自`sudo`改全盘ACL或禁用保护。

## 依赖与设置

1. Git同步需要系统Git（原型验收使用2.55）。认证使用自己的Git credential helper或ssh-agent，不在远端URL内嵌密码/token，不共享社区创建者高权限token。
2. 默认跨平台图片编码使用随程序AOT内置的纯Dart codec（默认lossless WebP），无需额外安装cwebp；具体大小/尺寸/帧限制以本包媒体实现为准。显式选择native `CWebpEncoder`备用路径才需要本机可信libwebp的`cwebp`绝对路径。Ubuntu/Debian包名通常为`webp`，Windows可自行从可信官方分发取得；本包不下载或执行外部安装器。
3. 有需要时可把自备Git/cwebp所在**绝对目录**设为`ZAIZUO_GIT_BIN_DIR`/`ZAIZUO_CWEBP_BIN_DIR`，launcher只对子进程临时PATH生效，不安装或下载它们。此变量不能替代媒体API对可信encoder绝对路径的校验。
4. Linux需要glibc、libstdc++、libgcc等动态运行库；以实际构建/验收系统为准。此包不是Alpine/musl专用构建，也不声称兼容所有旧glibc系统。
5. Windows AOT快照与运行时必须配套，不替换为别的Dart版本；不要只拷走快照。其他外部库依赖以实际宿主烟测为准。

`runtime.env.example` **不是可自动执行的脚本**；启动器不会source/dot-source它，也不保存秘密。设置必须由可信终端手工确认。不要把真实password/token写入该模板、批处理脚本或共享盘。

## 首次账号与运行

密码通过当前进程环境变量 `ZAIZUO_PASSWORD` 传入，不能作为命令参数。OneBot令牌用 `ZAIZUO_ONEBOT_TOKEN`，至少32个可打印ASCII字符；中继令牌用 `ZAIZUO_RELAY_TOKEN`。请使用密码管理器/受控启动环境注入，关闭会话后清理；此测试包不提供系统密钥库。

在 `ZAIZUO_PASSWORD` 已安全设置的终端：

```text
zaizuo init <本机私密资料目录> <账号名> <昵称>
zaizuo status <本机私密资料目录>
zaizuo join-init <新账号目录> <账号名> <昵称> <公开manifest文件> <仓库外确认的根指纹>
zaizuo join-request <新账号目录> <公开请求输出文件>
zaizuo admit <社区根账户目录> <公开请求文件> <公开manifest输出文件>
zaizuo command <本机私密资料目录> <操作名> <参数JSON文件>
zaizuo send <本机私密资料目录> <会话编号> <文本>
zaizuo send-file <本机私密资料目录> <会话编号> <本机文件> [MIME]
zaizuo send-image <本机私密资料目录> <会话编号> <本机图片>
zaizuo messages <本机私密资料目录> <会话编号> [数量]
zaizuo download <本机私密资料目录> <本机file_id> <明确输出路径>
zaizuo sync <本机私密资料目录> <独立空受管同步目录> <Git远端>
zaizuo serve <本机私密资料目录> <自己的bot编号> 6700
```

Windows把 `zaizuo` 替换成 `.\zaizuo.cmd`，Linux便携包替换成 `./zaizuo`。真实支持的最新命令以本包 `--help` 输出为准；新增媒体动作必须以实际实现与端到端测试为准，不能仅因保留了 `image` JSON消息段就宣称完整收发。

### 重要安全边界

- **资料目录与程序目录分离**。`unlock.factor`、`local-private.json`、`recovery.txt`、`state.enc`、本机映射和私密设备资料不得整体Git同步/发给他人。恢复材料离线保管；不要把整个profile当worktree。
- 首次加入必须核验仓库外指纹，不能因未知仓库同时提供“公钥+指纹”就自动信任。
- 后台Git设置：`ZAIZUO_GIT_REMOTE`与`ZAIZUO_GIT_WORKTREE`成对；`ZAIZUO_SYNC_INTERVAL_SECONDS`默认30、至少1。使用空专用同步目录，不接管普通仓库。
- OneBot只监听本机数字环回地址，默认6700；令牌只授权一个固定自己的bot。可选中继URL也按本机受控规则处理。本包不替你启动公网服务器或改防火墙。
- 成功返回只表示当前实现承诺的本机加密日志落盘，不等于对端已收到/已读/Git远端已持久化。
- 没有界面、通知、系统密钥库、Android后台/耗电验收、独立密码学审计。不能承诺零丢失、绝对全序、关系隐藏或全局即时撤权。

## Linux DEB

构建脚本可无root使用`dpkg-deb`生成测试.deb；**生成不等于安装**。系统安装需用户明确在目标机使用包管理器（会有管理员权限和依赖安装）；本包无preinst/postinst脚本，不自动创建服务/用户/资料目录。

不想系统安装，可无root解包：

```sh
mkdir -p "$HOME/.local/opt/zaizuo-test"
dpkg-deb -x ./zaizuo-cli_VERSION_ARCH.deb "$HOME/.local/opt/zaizuo-test"
"$HOME/.local/opt/zaizuo-test/usr/bin/zaizuo" --help
```

便携tar.gz通常更直接。卸载程序不等于删除账号资料；资料恢复/清理须由用户明确决定，不自动删除个人数据。

## 报告故障

提供平台/架构、`BUILD.json`、`--help`是否成功、稳定错误码；不要上传profile、私钥、password/token或明文聊天。Windows AOT已知Unicode编译器参数问题影响构建，不应以修改系统ACL、关闭保护或给管理员权限当作默认解决方法。
