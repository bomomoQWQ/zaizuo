# CLI 与 Android 验证壳打包工具

- `build-windows.ps1`：Windows x64，显式`-Mode Snapshot`（默认，AOT快照+运行时）或`-Mode Exe`（标准单文件编译成功才打包），支持`-DartExe / -OutDir / -Version / -SkipPubGet / -SkipSmoke`。
- `build-linux.sh`：Linux本机x64/arm64，支持`--dart / --out-dir / --version / --deb auto|yes|no / --skip-pub-get / --skip-smoke`，portable tar.gz与可选deb；不sudo。
- `android.ps1`：最小Android本机媒体验证壳debug APK，显式工具链/隔离SDK、`-Target / -Version`，只检查依赖，不自动下载组件或接受许可。版本化输出到`dist/packages`且拒覆盖；不是完整Android IM。工具及实际产物见[Android构建](<../../docs/Android构建.md>)。
- `collect_licenses.dart`：只按精确package_config收集依赖许可证，缺第三方license就停止，不拷贝用户资料。
- `PORTABLE-README.md`、`runtime.env.example`：无秘密的包内说明/模板；启动器不会自动读取或执行配置模板。
- `aot_probe.dart`：无业务/秘密的编译工具探针，不进入最终包。
- `collect_licenses_test.dart`：独立自测收集成功、第三方缺许可失败、危险包名拒绝；显式传入新的`.local`测试根目录，不能给用户资料目录。
- `smoke_package.dart`：对已解压便携包真实执行init/status/send-file/send-image/messages/download/重开，核对二进制字节与实际WebP容器；参数为`<包目录> <新的.local测试目录>`，不使用真实账号。Dart只启动测试工具，所有业务子进程执行包内AOT/runtime或native binary。

详细环境、已复现的Windows Unicode gen_snapshot失败与阶段诊断、平台安装/解包方式见[构建与安装](<../../docs/构建与安装.md>)。

重要：当前宿主明确拒绝直接执行部分PowerShell脚本，`build-windows.ps1`只经AST语法检查；**不改执行策略、不Invoke-Expression、不重试别shell绕过**。本轮Windows实际产物由用户授权的独立native命令流水线和手动显式allowlist组装，不冒称脚本已跑。Linux Bash脚本本地通过`bash -n`；父流程已在Ubuntu24.04.4/Dart3.14/Git2.43真实执行exit0并产native tar.gz/.deb。后续安全patch需重新构建与烟测，不能沿用旧binary。

不覆盖既有同名包，不自动删构建目录，不复制.profile/.env/私钥/secret，不创建远端、不commit/push。项目许可证未定，所有产物暂为内部测试，不擅自公开分发。
