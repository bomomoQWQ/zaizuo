# CLI 与 Android 验证壳打包工具

- `build-windows.ps1`：Windows x64，显式`-Mode Snapshot`（默认，AOT快照+运行时）或`-Mode Exe`（标准单文件编译成功才打包），支持`-DartExe / -OutDir / -Version / -SourceRef / -SkipPubGet / -SkipSmoke`。
- `build-linux.sh`：Linux本机x64/arm64，支持`--dart / --out-dir / --version / --source-ref / --deb auto|yes|no / --skip-pub-get / --skip-smoke`，portable tar.gz与可选deb；不sudo。
- `android.ps1`：最小Android本机媒体验证壳debug APK，显式工具链/隔离SDK、`-Target / -Version`，只检查依赖，不自动下载组件或接受许可。版本化输出到`dist/packages`且拒覆盖；不是完整Android IM。工具及实际产物见[Android构建](<../../docs/Android构建.md>)。
- `collect_licenses.dart`：参数`<package_config.json> <pubspec.lock> <output-dir> [project-root]`；默认root为脚本所在项目，fixture/源码副本应显式传root。仅将root内`packages/`下的`zaizuo_*`视为owned，逐字复制根`LICENSE`/`NOTICE`至`licenses/zaizuo/`及各owned包目录。其他依赖只按精确package_config包根收集原许可；名字带`zaizuo_`的外部pathdep也不能冒认owned，不从祖先目录补第三方许可。缺根声明或第三方license就停止，不拷贝用户资料。
- `PORTABLE-README.md`、`runtime.env.example`：无秘密的包内说明/模板；启动器不会自动读取或执行配置模板。
- `aot_probe.dart`：无业务/秘密的编译工具探针，不进入最终包。
- `collect_licenses_test.dart`：独立自测第三方字节保留、owned AGPL+NOTICE、外部pathdep/相似路径隔离、缺根声明与缺第三方许可失败、危险/重复包名拒绝；显式传入新的`.local`测试根目录，fixture自行创建根LICENSE/NOTICE，不能给用户资料目录。
- `smoke_package.dart`：对已解压便携包真实执行init/status/send-file/send-image/messages/download/重开，核对二进制字节与实际WebP容器；参数为`<包目录> <新的.local测试目录>`，不使用真实账号。Dart只启动测试工具，所有业务子进程执行包内AOT/runtime或native binary。

详细环境、已复现的Windows Unicode gen_snapshot失败与阶段诊断、平台安装/解包方式见[构建与安装](<../../docs/构建与安装.md>)。

## 许可、源码与重打包边界

项目原创代码已由维护者选择 **AGPL-3.0-only**，见[根LICENSE](<../../LICENSE>)和[根NOTICE](<../../NOTICE>)；第三方许可逐字保留。两个CLI构建脚本在打包前要求根声明非空，包根附LICENSE/NOTICE/SOURCE.md，`BUILD.json`写入`project_license`、`source_repository`、`source_ref`、`source_url`、`source_archive`；DEB在`/usr/share/doc/zaizuo-cli/`保留这些说明和完整AGPL版权文件。`SourceRef`/`--source-ref`默认`v<Version>`，发布者必须核验标签与实际源码一致，不能把未发布或不相干的标签当对应源码。

本轮`0.1.0-media-test3`固定对应：<https://github.com/bomomoQWQ/zaizuo/tree/v0.1.0-media-test3>；源码免费下载：<https://github.com/bomomoQWQ/zaizuo/archive/refs/tags/v0.1.0-media-test3.tar.gz>。发布时应保留同标签源码及构建脚本/锁定文件，并遵守AGPL第6节和适用的第13节；公开源码不是生产安全或兼容性保证。

重要：当前宿主明确拒绝直接执行部分PowerShell脚本，`build-windows.ps1`仅做AST语法检查；**不改执行策略、不Invoke-Expression、不重试别shell绕过**。Windows test3使用获准的PowerShell API把test2已验证ZIP按完整allowlist复制至新`.local`stage，仅更换许可、说明与BUILD元数据后重算清单/归档，**不是运行PS1或重新编译**。BUILD明确记录原包SHA256、`repackaged=true`及业务源码/core/bin零改动；原包二进制和所有第三方LICENSE必须逐文件同SHA。新ZIP再解压，全量核验内部SHA256SUMS，并用`smoke_package.dart`真实执行文件/图片WebP下载与重开测试。Linux Bash脚本以`bash -n`检查，原生编译/测试须在Linux宿主另做，不能拿语法检查声称构建已跑。后续业务或安全patch必须重新构建与烟测，不能沿用旧binary。

默认构建脚本的smoke只是`--help`（BUILD写`smoke_scope=help-only`）；媒体/重开验收需额外运行`smoke_package.dart`。不覆盖既有同名包或摘要，不自动删构建目录，不复制.profile/.env/私钥/secret；工具不创建远端、不commit/push。发布需由维护者另行执行，脚本不自动上传包。
