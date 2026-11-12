# Git 内容同步适配器

本轮实现的是 `GitSync`：真实调用 `Process.run` 的系统 Git，为 `FileEventStore` 搬运原始密文信封；不是 mock Git、不是账号认证器，也不管理托管平台令牌。不会连接用户的 NapCat、现有仓库或预设真实远端。本轮没有提交或推送项目代码；测试中的 push 只指临时目录的本机裸仓库。

## 公开接口

```dart
static Future<GitSync> GitSync.initialize({
  required Directory worktree,
  required String remoteUrl,
  required String deviceId,
  int segmentSize = 32,
  int maxEvents = 100000,
  int maxSegmentBytes = 64 * 1024 * 1024,
  int maxDevices = 1024,
  String gitExecutable = 'git',
});

String get branchRef; // refs/heads/dev/<64位小写hex设备ID>
Future<int> push(FileEventStore store);
Future<int> pull(FileEventStore store);
Future<void> close();

class GitSyncException implements Exception {
  final String code;
  final String message;
}
```

`worktree` 必须是最初为空的**专用同步目录**，或本适配器已初始化的相同目录。为了避免继承用户仓库的 include/filter/hooks 等配置，不接受已有普通 clone、linked worktree、bare repo 或非空目录。这里的 clone 是通过 `init + fetch + plumbing` 建立的专用本地副本，不执行 `git clone` 的默认 checkout。此目录不可再作为手动开发工作树使用。

`deviceId` 必须是已授权设备的完整 64 位小写 hex 编号。初始化本身不联网，也不推送。后续 `push/pull` 的信任来源始终是 `store.trust`；第一次使用会把社区编号绑定到本地 pin 文件，之后不同社区直接拒绝。

- `push` 返回新归档的**本设备**事件数量。无新增事件重复调用返回 0，不生成新提交。网络结果不明确时保留本地提交，重试可重复使用。远端必须接受非 force 的 fast-forward 更新。
- `pull` 返回 `store.import` 实际新落盘的事件数量。重复拉取返回 0；store 验签、链校验并 flush 后才算导入成功。
- `close` 等待已排队的操作完成；不会删本地目录、pin 或锁文件。关闭后 `push/pull` 抛 `StateError`。
- Git 失败用 `GitSyncException`，格式/验签/链异常也可能直接传播 `FormatException` / `StateError` / 文件系统异常。不应捕获所有错误后假称同步成功。

最小用法（`trust` 和设备授权证书必须已由上层依据可信社区根建立）：

```dart
final store = await FileEventStore.open(localStoreDirectory, trust);
final sync = await GitSync.initialize(
  worktree: privateCloneDirectory,
  remoteUrl: configuredRemoteUrl,
  deviceId: authorizedDeviceId,
);
try {
  await sync.pull(store);
  await sync.push(store);
} finally {
  await sync.close();
  await store.close();
}
```

## 设备分支、归档与归并

设备事件接口 `push/pull` 只发布 `refs/heads/dev/<deviceId>`，不会更新 `main`、别的设备分支或远端配置。社区根、成员授权的签名 manifest 现由下文单独的 `CommunityGit` / `readManifests` / `publishManifest` 接口运输；不会与设备事件互相改写。收到新的设备分支也**不会自动信任**其证书，必须事先存在于可信 `TrustStore`。

一个设备分支的完整 tree 只允许：

```text
logs/<deviceId>/00000000.jsonl
logs/<deviceId>/00000001.jsonl
...
```

编号从 0 连续；除最后一段外，每段恰好 `segmentSize` 条。默认 32；这是原型归档协议参数，参与同社区同步的实例必须一致，不能悄悄改变。每行是 `canonicalJson(event.toJson())` 加一个 LF，不含明文业务消息；要求规范化格式，无空行/CR/不完整尾行。文件必须是 Git mode `100644` 的普通 blob。额外路径、可执行位、symlink、submodule/gitlink 均拒绝。远端 Git commit 不依赖作者名或 Git 签名作为事件授权证明。

发送时只取 `store.allEnvelopes.where((e) => e.origin == deviceId)`，按设备序号验证连续链后发布。接收的别台设备信封只留在本地日志；即使收到了同一个群的消息，也不会拷贝到本设备 branch 或重写 source branch。原密文、nonce、tag、header、signature 保持不变，不重新加密。各分支不 merge、不 rebase，归并发生在本地 `EventIndex`。

接收检查依次包括：设备分支名、commit 类型、树/分段结构、信封 origin 与分支设备一致、完整连续序号、previous、单调设备逻辑时钟、授权及签名。先把**本轮所有分支**送入候选索引预验，全部通过才调用 `store.import`。因此坏签名或分支内冲突不会导致本轮先接受一部分有效远端事件。磁盘 I/O 失败则可能已 flush 一部分有效事件；不会推进 pin，重试去重，不承诺跨 store/pin 文件的全局事务。

## 本地 pin 与回退保护

本地状态在 `.git/zaizuo-sync/`：

- `identity.json`：适配器版本、无凭据远端地址、本设备、分段参数。
- `pinned_refs.json`：社区编号和 `pinned_refs: {完整设备ref: 已验收commit SHA-1}`。
- `empty-hooks/`：受控空目录。

这些文件不加入 Git tree。另有私有 `refs/zaizuo-pins/<deviceId>` 保留已钉住对象，防止普通 GC 删掉后无法验证祖先。临时抓取使用一次性 `refs/zaizuo-incoming/<随机值>/...`，结束删除；不复用有陈旧分支的 remote-tracking refs。

每次抓取后，对每个已 pin 分支要求：

1. 分支仍存在；删除返回 `remote_deleted`，不能当作设备没有消息而忘掉旧 pin。
2. 旧头是新头祖先；force-push 到旧提交或不相关分叉返回 `remote_rewrite`。
3. 已 pin 头的签名事件序列是新头事件序列的原样前缀；即使 Git commit 是 descendant，也不能删改历史归档（`archive_rewrite`）。

`push` 同样先检查 pins，不会在远端被删或回退后擅自“修复”并重推。local/remote 同设备头已分叉也拒绝覆盖。只给成功验收的内容推进 pin，采用同目录临时文件 flush 后 rename 替换；不先删除旧 pin。pin 缺失/损坏失败关闭，不自动清空重信任。**pin 是本地信任记忆，不是从远端 clone 后就有的可靠历史**；首次见到的分支仍是首次使用信任，无法发现首次安装前被隐藏的合法历史或完全删掉的未知分支。

恢复被删除/分叉的分支、设备克隆迁移、pin 备份/导入或显式重置信任，需要上层有用户确认的恢复流程；当前没有绕过检查的 `force` API。

## 社区 main：CommunityGit

`CommunityGit` 与事件同步共享**同一套**受控 Git 命令通道、专用 clone、跨实例/进程锁与凭据约束，不另建可执行任意命令的 transport。GitSync 仅新增两项固定 main 用途的公开接口：

```dart
Future<List<CommunityManifest>> GitSync.readManifests({
  required String pinnedFingerprint,
});
Future<int> GitSync.publishManifest(CommunityManifest manifest, {
  required String pinnedFingerprint,
});

CommunityGit({
  required GitSync repository,
  required String pinnedFingerprint,
});
static Future<CommunityGit> CommunityGit.initialize({
  required Directory worktree,
  required String remoteUrl,
  required String deviceId,
  required String pinnedFingerprint,
  String gitExecutable = 'git',
});
Future<CommunityManifest?> pull();
Future<List<CommunityManifest>> readHistory();
Future<int> publish(CommunityManifest manifest);
Future<void> close();
```

借用 `GitSync` 构造的 facade 关闭不关闭底层共享 repo；`CommunityGit.initialize` 自建的则负责关闭。`pinnedFingerprint` 必须通过邀请、线下/其他仓库外可信渠道核验，不能拿当前仓库自报根自动填进去。它是 `CommunityManifest.fingerprint()` 的值，绑定社区和根签名公钥，不是账号 ID 或 Git commit hash。

main tree 严格只允许普通 `100644` 文件：

```text
manifest.json                  # 最新签名 manifest 的完整副本
manifests/00000001.json         # revision 1
manifests/00000002.json         # revision 2
...
```

每个文件是规范化 `CommunityManifest.toJson()` 加 LF。每次接收从 revision 1 开始逐条验外部根指纹、根签名、revision 连续递增、`previous_hash == objectHash(previous.toJson())`；不以“最新一份签名有效”跳过中间版本。根指针必须和最后一份历史记录完全相同。单记录上限 4 MiB、最多 10000 个 revision，树中额外代码/hooks/filter/submodule/symlink/executable 路径一律拒绝，也不 checkout。

发布只运输**已经由根 owner 签好的公开 manifest**，不接收 Identity 私钥、账号密码或 Git token。仅根签名能通过发布前验证；错根/坏签名在调用远端或 credential helper 前拒绝。相同最新版本重试返回 0；正常新版本返回 1；跳版本、替换已见版本、发布过时版本或 Git 分叉均拒绝。适配器没有 force 覆盖 API。Git 托管 ACL 仍需独立把 main 写权限只给维护者：签名检查不能阻止另一个客户端直接删远端数据或绕开本适配器 push。

`CommunityManifest` 顶层是社区 root/owner、accounts 及 settings 元数据。`settings.devices` 存设备证书公开 JSON，`settings.keys` 存签名绑定社区/recipient 的密钥密文信封；Git 层不解释这些业务字段，runtime 应验证 typed cert/grant 再修改本地信任。**不得存私钥种子、口令、vault、恢复材料、Git 凭据或明文会话密钥**。任意用户字段的字符串可能伪装秘密，Git 层不是通用数据泄露检测器；应由调用方仅用安全元数据构造 manifest。拉取成功也不会擅自覆盖本机 seed/私钥或自动批准未知设备。

本地主配置记忆独立放在 `.git/zaizuo-sync/community_checkpoint.json`，包含固定根指纹、社区编号、Git head、latest revision、latest manifest hash；另有 `community_initialized` 标记及私有 `refs/zaizuo-community-pin` 留住对象。这些都不进远端 tree。首次 main 不存在合法返回空历史/null；已钉住 main 消失报 `remote_deleted`。每次要求 Git 旧头为新头祖先，拒绝 force 回退/不相关分叉；再验证新历史在已验收 revision 处的 hash，拒绝 descendant commit 改写历史。只有全链验证成功才 flush/rename 推进 checkpoint。checkpoint/初始化标记丢失拒绝静默重信任。

首次安装仍无法知道托管方隐藏了尚未见过的更高合法 revision；外部根 pin 不等于外部 latest revision 证明。主配置显式更新/恢复策略仍应由 owner 与 runtime 决定，不自动 reset 根信任或把仓库任意状态覆盖本机。当前完整历史在每次读取全量验证，适用原型规模，不承诺无限历史或严格全局事务。

## Git 执行及凭据边界

- 所有进程调用均为 `Process.run(gitExecutable, List<String>, runInShell: false)`。远端通过明确参数传入，不拼 shell 命令，不执行任何远端树里的文件，不 checkout、不初始化 submodule。
- 远端仅接受已存在的本机绝对目录、`https://host/path`、`ssh://[user@]host/path`。拒绝 UNC、相对路径、scp 简写、http/git/file/ext transport、`ext::`、控制符、URL query/fragment、percent 编码、HTTPS userinfo、SSH 密码。SSH userinfo 只允许普通用户名。带空格/中文的本机绝对目录正常工作。
- URL 只代表仓库位置，不可把 token 塞在 path 里伪装成仓库名；语法检查不能推断任意路径内容是否是秘密。API 不接收、储存或记录密码/token。
- 清除继承的 `GIT_*` / `GCM_*` 环境覆盖，隔离系统/全局 Git 配置；本地 config 必须精确匹配受控最小配置，修改后 fail closed。这牺牲了自定义 proxy、insteadOf、CA、filters、sshCommand 等自动配置兼容性，不能把现有用户仓库配置复制过来“修好”。
- 唯一有意继承的 Git 配置是 HTTPS 需要的系统/全局 `credential.helper`：只读到内存，排除 `!shell` 和含元字符的 helper；使用标准 helper 名及简单选项，不支持路径式/custom shell helper、include 间接配置或 URL 定向 helper。helper 本身及系统 Git/ssh 可执行文件是本机受信任依赖。
- SSH 使用系统 `ssh`、已有 ssh-agent/known_hosts/系统 SSH 配置，强制 BatchMode、PermitLocalCommand=no、ClearAllForwardings=yes；不自动接受未知 host key。无交互凭据时 Git 报错，不落盘 token。SSH 的用户系统配置本身是本机信任边界，不把远端 Git tree 当 SSH 配置。
- 每个 Git 命令都设置受控空 `core.hooksPath`，并禁 `protocol.ext.allow`、所有非明确允许 transport、自动 submodules、自动维护/GC、签名程序、fsmonitor。受控 hooks 目录变为非空会报错。仓库根 `.git/hooks` 中的本地 hook 被忽略。
- **本机 file transport 的 receive-pack/upload-pack 不继承客户端 `-c core.hooksPath`**，所以每次本机 fetch/push 前还独立检查远端：必须是普通裸仓库，仅允许 core 的固定 metadata/布尔项，拒绝 include、自定义 hooksPath、receive.procReceive 等所有非白名单配置；hooks 目录只允许普通 `.sample` 文件，活动 hook/链接直接拒绝；拒绝 commondir/shallow/alternates。检查前不让 Git 解析远端配置。网络托管方自己的 server hooks 不受客户端控制，但不会在客户端执行对象树代码。
- 写树使用私有临时 index、`hash-object --no-filters`、`update-index`、`write-tree`、`commit-tree`，不会读取用户 stage，也不会让 `.gitattributes` 执行 filter。读远端内容用 `ls-tree`、`cat-file -s`、`git show --no-ext-diff --no-textconv`。
- 错误不拼接 Git stderr、完整 argv 或远端输出，避免 helper/server 回显凭据。返回稳定操作名和退出码；需要凭据诊断时由用户在受信任环境自行检查 Git，而不是让适配器记录秘密。

本机绝对远端目录的 Git 管理元数据、系统 Git/credential helper/ssh 及本地文件系统权限应可信；对象树不可信。拥有修改本地 `.git`、pin、环境或 Git 可执行文件权限的攻击者不在此原型安全边界内。托管方仍能阻断传输或不给出尚未被本地观察的内容；签名和 pins 不保证可用性或零丢失。

## 并发与资源边界

同一个规范化 clone 路径由 isolate 内共享队列串行，跨进程用 clone 同级 `.名称.zaizuo-sync.lock` 文件的 OS 排他锁覆盖整轮操作；Windows路径队列键忽略大小写。锁留在本地不入 Git；进程退出由 OS 释放。锁文件不删除，避免删锁造成竞争。

这是**单设备单受控 clone**的并发保护，不是允许多台独立设备/clone共用一份私钥的分布式 multi-writer 协议。不同 clone 并发发同设备的不同链，会被 Git non-fast-forward、签名链或本地分叉检查拒绝，不能自动挑赢家。POSIX advisory locks 不阻止不合作程序；同进程不同 isolate 不应直接共享此 clone（某些平台锁按进程记账），调用方应集中到一个同步 isolate。网络文件系统/移动端文件锁及崩溃持久性需要另行实测。

默认上限为每设备/每次拉取最多 100000 条、每段 64 MiB、1024 个设备分支，单段最多 1000 条。读取 blob 前检查 Git 记录的 size，但 fetch 包/commit 历史、ls-tree/ref 输出的总大小与进程耗时尚未硬限流。恶意远端仍可耗磁盘/带宽或让 Git 等待；生产版本需要进程取消/超时、pack/磁盘配额、增量校验缓存与压测。现实现每次重验全分支，发布也重建本设备全部归档树，定位为非界面可测原型。

只处理 SHA-1 Git object format 的受控仓库；事件加密/签名沿用 core 的 Ed25519/AES-GCM，Git object ID 不是密码学授权。要求系统 Git 支持本实现使用的 init/fetch/plumbing 参数；当前实际验收 Git for Windows 2.55.0、Dart 3.14.0，不推断 Android 已具备系统 Git。

## 本机集成测试

```text
dart test test/git_sync_test.dart test/community_git_test.dart --reporter expanded --concurrency 1
```

测试不使用 mock Git。每个 fixture 在临时目录创建一个裸仓库和多个受控 clone，并真实 push/fetch/读树/验签/落盘。18 项测试覆盖多设备原信封往返与解密、分段、重复导入、坏签名全轮预验、origin/branch 不符、缺链、首次接收与已见本地链分叉、force-push 回退/分叉、descendant 删历史、删除已 pin 分支、pin 持久重开/丢失、同 clone 多实例并发、外部进程 OS 锁、可执行/symlink/gitlink tree、本地受控与裸远端 hooks/config、filter/submodule 元数据、URL凭据和用户现有仓库保护。没有真实账号密码、token、托管远端或公网监听。运行结束只回收 fixture 自建临时目录。

另有 15 项 main 集成测试覆盖初始空分支、签名 main 多修订两 clone 往返、main/dev 共存互不改写、错误外部根、错误发布签名先于 transport 被拒、坏中间签名、缺失修订/错误 previous_hash、最新根指针、checkpoint 重开后回退、不相关 force-push、descendant 改已见签名历史、分支删除、checkpoint 丢失、跳版本发布与裸远端 hooks。GitSync 两项受限 main API 与 facade 均通过静态分析。

这些测试证明所覆盖本机路径的行为，不等于 HTTPS/SSH 实网、所有系统 helper、断电耐久、移动端集成或经审计的生产安全保证。
