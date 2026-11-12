# 在座

对机器人友好的独立聊天软件。目标客户端为 **Flutter：Linux / Windows / Android**；目前已经实现并测试的是 **非界面 Dart 原型、OneBot 11/12、Go 独立 / Dart 可嵌入双中继**，不是 QQ 桥接器，也不是 NapCat 插件。

**本地可运行，不等于已经生产就绪。** 尚无 Flutter 页面或安装包，未接第三方真实账号、Android 系统密钥库或公开网络部署。项目许可证待维护者决定，不自动创建远端或推送。

## 已经有的代码

| 模块 | 已实现能力 | 说明 |
|---|---|---|
| [加密与日志内核](<packages/core/>) | Ed25519 签名、X25519 收件者封装、Argon2id 密码+第二因素钥匙箱、设备授权、加密事件链、锁定 JSONL 日志、附件密文存取 | 未经第三方密码学审计；原生图像解码不是安全沙箱 |
| [业务内核](<packages/domain/README.md>) | 主账户和多个机器人、草案/名额、群聊/频道/私聊、茶会、闺房、论坛、朋友圈、管理和历史资格区间 | 纯状态机，不信任远端状态补丁 |
| [Git 同步](<packages/core/GIT_SYNC.md>) | 根签名 main 逐修订名册、每设备密文分支、外部指纹、已见历史回退/删除/分叉拒绝 | 使用专用目录；实际网络托管与 Android Git 仍待适配 |
| [OneBot 11/12](<packages/onebot/README.md>) | 本机 HTTP、正向/反向 WebSocket、固定机器人绑定、持久 v11 ID、论坛/朋友圈 `zaizuo.` 扩展 | 支持矩阵明确，不冒充全规范；无撤回、媒体文件动作 |
| [Go 独立中继](<relay-go/README.md>) / [Dart 可嵌入中继](<packages/relay_dart/README.md>) | 同一受限 WebSocket 协议、不透明转发、鉴权/限流/背压/有界关闭 | 不存历史、不验业务签名、不分发密钥、不保证送达 |
| [应用协调与命令行](<packages/runtime/README.md>) | 账号初始化/入驻、持续 Git 同步、会话期次密钥分发、可选中继加速、机器人服务、加密重放 | 所有写入先本机持久化，再向外回成功；仍为原型 |

**项目正式名：在座；代码/平台标识：`zaizuo`；OneBot 扩展前缀：`zaizuo.`。**

## 快速入口

需要 Dart SDK、Go（仅独立中继）及系统 Git。各 Dart 包独立执行 `dart pub get`；仓库没有 Flutter SDK 或外部平台客户端依赖。已有便携 SDK 仅保留于本机忽略目录，不包含在版本库中。

在应用包目录：

```text
dart run bin/zaizuo.dart help
dart run bin/zaizuo.dart init <本机私密资料目录> alice 爱丽丝
dart run bin/zaizuo.dart command <目录> bot.register <参数JSON文件>
dart run bin/zaizuo.dart sync <目录> <独立空同步目录> <Git远端>
dart run bin/zaizuo.dart serve <目录> <机器人编号> 6700
```

密码使用当前进程环境 `ZAIZUO_PASSWORD`，本机协议令牌使用 `ZAIZUO_ONEBOT_TOKEN`。不要把真实密码写入命令参数、示例、源码或日志。初始化默认使用正式 KDF 参数；测试专用小内存参数不得用于实际账号。

第二账号的入驻、Git 凭据、中继及持续运行配置见 [命令行说明](<packages/runtime/README.md>)。主账号密码并不是 GitHub 登录凭据；不能把创建者的高权限 PAT 发给整个社区。

## 验证

- [验收记录](<docs/非界面验收记录.md>)：实际测试数量、端到端场景、未验证项。
- [本机检查入口](<tools/check.ps1>)：各 Dart 包 format / analyze / test，以及 Go test / vet / build。宿主不允许执行脚本时，使用验收记录列出的直接 SDK 命令，不改变系统执行策略。
- [真实双中继互通](<tools/relay_interop/README.md>)：同一个客户端对当前 Go/Dart 真实子进程执行协议与重启测试，不是中继桥接，也不证明普通测试 payload 具备加密。

## 安全和完成度

先读 [当前架构与实现边界](<docs/当前架构与实现边界.md>) 和 [非界面后续待办](<docs/非界面后续待办.md>)。重要区别：本机 flush、Git push、中继 ack、对端接纳是四种不同状态；有签名不等于有业务权限，私有仓库不等于私聊隔离。

目前 **未完成或未验收** 的非界面事项也会继续单列：系统安全存储、扫码设备授权的完整应用生命周期、真实图像编解码与附件 Git/按需传输、移动端 Git/调度、密码/设备丢失恢复、名册移除/根轮换、并发换钥人工裁决、大规模与真实公网验证。不会把这些藏在“以后做界面”里。

不承诺零丢失、绝对全序、无限免费、不可钓鱼或零合规风险。端到端内容加密也不隐藏网络地址、设备分支、会话成员关系与流量时序。

## 历史与项目约定

- [工作约定](<AGENTS.md>)
- [非界面实现契约](<docs/非界面实现契约.md>)
- [双中继线协议 v1](<docs/中继协议-v1.md>)
- [历史架构讨论迁移原件](<docs/archive/架构讨论稿-迁移原件.md>)：包含旧错误和矛盾，**不是安全规范**，原件不修改。

历史原稿来源为本机 NapCatQQ 提交 `4cce149b` 中的资料，迁移逐字节一致，SHA-256：`c552064f82ddbc63580cf2eda83367e974558f0fc8ec7d5393d6bdb4c8881710`。本项目代码从独立空历史开发，没有复制 NapCat 实现、二进制或许可证。
