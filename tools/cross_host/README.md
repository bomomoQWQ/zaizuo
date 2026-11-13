# 真实跨电脑媒体验收工具（仅丢弃式测试）

本工具分阶段在 Windows 与维护者授权的 Ubuntu 上运行；真实创建独立 `LocalProfile`、根签名入驻名册、Git/SSH 设备日志、密文附件与按需取回。结果见[本轮验收](../../docs/图片文件与跨平台验收.md)。

**只用于新建临时测试资料。** 工具内置公开假口令，使用 tiny KDF 加速；不是正常用户初始化/部署工具，不得对真实 profile 执行。正常 CLI 保留默认强 KDF。不要传入私钥路径，不读取 Xshell 配置，不共享根账户资料；只交换公开社区 manifest、仓库外确认的根指纹及签名加入请求。

## 前提

- 两台机器各有 Dart 3.14 及 Git，同一源码/依赖锁，包内执行 `dart pub get`（隔离缓存环境可 `--offline`）。
- 一个维护者授权的空 bare Git transport；同步目录与私密资料分离。
- SSH 使用各设备自己的既有身份和严格 host-key 检查，不在 URL 内嵌口令/令牌。创建仓库/网络服务前应明确授权，不运行 sudo 或改防火墙。

本轮远端仅 `/home/bomomo/zaizuo-lab/data/transport.git`；工具不会自动选择未授权远端，不创建或推送本项目 GitHub 远端。

## 阶段

```text
dart run bin/peer.dart <stage> <privateRoot> <transportRemote> [publicExchangeFile]
```

1. Windows `prepare-a`：创建 Alice 测试资料、频道并同步，导出 privateRoot 内 `public-community.json`。只把此公开文件交给 Ubuntu。
2. Ubuntu `prepare-b ... <公开community文件>`：创建独立 Bob 资料，核对外部根指纹，产生 `join-request.json`；只将签名公开请求交给 Alice。
3. Windows `admit-a ... <Bob公开请求>`：根账户明确接纳签名请求，发布连续 manifest。
4. Ubuntu `join-b`：获取名册与日志、加入频道、建立合法 epoch 收件资格。
5. Windows `send-a`：生成 12,050 字节 binary 与 48×32 RGBA PNG；真 WebP 编码、加密暂存、目的 scope 重加密、Git 归档，输出文件摘要。
6. Ubuntu `receive-b`：按需取回并解密文件/图片，文件摘要、尺寸和每一 RGBA 通道均检查；Bob 独立编码透明PNG并重新加密回传文件和WebP图片。
7. Windows `verify-a`：取回 Bob 文件和图片回件，验证完整文件摘要与图片每个RGBA通道（包括alpha=0的隐藏RGB）。两端 `rejected` 必须为 0。

工具不启动公网监听或安装系统服务。各阶段需要网络凭据可用；SSH 失败、事件拒绝、图片像素不一致均失败，不把 relay ack 当已落盘。

结果是指定局域网/小文件验证，不代表 GitHub、HTTPS、公网、弱网大文件、Android 或真实机器人框架都通过。保留测试 profile 供维护者检查，不能提交 Git；删除时先核验精确测试目录，禁止顺手清理服务器其他用户数据。
