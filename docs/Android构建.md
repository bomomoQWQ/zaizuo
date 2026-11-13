# Android 安装验证壳：构建与验收边界

## 这是什么，不是什么

[mobile_probe](../apps/mobile_probe/README.md) 是最小 Flutter Native **debug/internal 安装验证壳**：显示 Android/Dart 环境，初始化应用私密测试资料，选择系统文件或运行内置 PNG，调用真实 `PreferredImageEncoder` 输出 WebP，再用真实 `EncryptedAttachments` 密文落盘与解密校验、预览。

它不是正式 IM 页面、完整 Android 客户端或跨电脑同步客户端。**Android Git 适配器未实现，壳内明确显示不可同步；不调用系统 Git，不把接口 mock 当 Git 成功。** 没有登录真实服务、通知、后台调度、相机或第三方平台接入。手机/模拟器上的安装、启动、文件选择器和性能必须另外实测，构建成功不等于真机验收。

## 资料和权限

- Android `getNoBackupFilesDir()/probe` 下存测试 profile、测试口令、解锁因素和加密对象；关闭 Android backup，未申请宽泛相册/存储权限。
- 本机测试口令与因素在同目录，**不是 Keystore、不能宣传为独立第二因素保护**。资料用于探针，不接收真实账户口令。
- 系统 `ACTION_OPEN_DOCUMENT` 按用户操作提供只读 `content://` 输入；不把 URI/文件名当系统路径，不保留持久 URI 权限，读取最多 8MiB。外部 ContentProvider 本身可能卡顿；线程/像素限制不是 OS 沙箱。
- 仅静态 PNG/JPEG/WebP，最多 4M 像素、边长 4096；lossless WebP 不保证输出比输入更小。透明像素/16-bit/JPEG 语义继承 core 编码器说明。
- 所有 manifest（含 debug）不声明 INTERNET，`usesCleartextTraffic=false`；本壳不上传所选文件、不启动端口。系统文件提供者自身的联网行为不属于本壳权限控制。
- 错误只展示固定诊断，不输出令牌、密码、私钥、照片内容或任意异常。解密预览仅在本机内存，卸载测试包会清除私密测试目录。

## 便携工具链（不改系统）

本轮主机：Windows x64，明确使用 `C:\Program Files\Java\jdk-17`（17.0.12），不使用 PATH 里默认 Java9。

Flutter 已从官方仓库浅克隆 tag `3.50.0` 到 `.local/flutter`，已验证 commit `ab2912035e160d9cad6306df307576da6128ebdb`。依据父代理预先校验的 releases JSON，完整 zip 为 **1,868,535,132 bytes**；本轮没有下载该 zip。浅克隆 `.git` 约 **39,658,737 bytes**，Android engine artifacts 由 `flutter precache --android` 缓存；后续实际构建要求的 NDK 由父代理按下述明确版本独立安装，未下载完整Flutter archive。

Flutter engine `371f77202a73e8dff57a8b3bff75bca55c090aee` 的 DEPS 所钉 Dart revision 与现有 `.local/dart-sdk/revision` 精确相同：`fa8c1270c374c1346931583a17c3b7f278d3822d`（3.14.0）。经父代理明确许可，Flutter 自己 `bin/cache/dart-sdk` 以 junction 指向该 SDK，**没有复制或下载第二份 231,471,855-byte Dart archive**。本轮不得运行 Flutter upgrade 或允许 engine 变化后替换这个 junction；engine stamp 不一致时构建脚本直接停止。

父 Dart 可执行文件构建前 SHA-256：`df42eb0c168858701f584615f90ee2a4b3d743a8a6dfd44036d38c4d898feb71`；交付时再次核对。

### Android SDK 与许可

共享 SDK 位于 `C:\Users\16706\AppData\Local\Android\Sdk`，仅按只读来源使用。已有 platform `android-34` revision3、build-tools `34.0.0`、cmdline-tools/latest、platform-tools 和现存 licenses 被复制到 F 盘 `.local/android-sdk`（约 413MB），Gradle 不写 C 盘 SDK。

读取到的已有 `android-sdk-license` hash 为 `24333f8a63b6825ea9c5514f83c2829b004d1fee`。**不运行 `yes | sdkmanager --licenses`，不自动替用户接受新许可。** 初始尝试使用SDK34，但实际Flutter/AGP要求更高构建组件；父代理已通过官方sdkmanager仅在F盘隔离SDK安装 `ndk;28.2.13676358`、`build-tools;36.0.0` 和 `platforms;android-36`，没有修改C盘共享SDK，许可文件SHA-256与C盘原件保持一致。最终显式配置 **compileSdk36 / buildTools36.0.0 / NDK28.2.13676358，targetSdk34 / minSdk24不变**：编译SDK升级不等于放宽权限或提高声明目标版本。仍设置 `android.builder.sdkDownload=false`，由构建脚本预检查已安装组件，不让Gradle隐式安装或接受新条款。

Gradle9.5越过DSL错误后曾明确要求尚未配置的 **NDK28.2.13676358（r28c）**，现该版本已由父代理安装到隔离SDK，source.properties核实为r28c。已只读核对 [Google官方repository元数据](https://dl.google.com/android/repository/repository2-1.xml)：Windows archive [android-ndk-r28c-windows.zip](https://dl.google.com/android/repository/android-ndk-r28c-windows.zip)，**748,118,221 bytes**，SHA-1 `086bba43ff2f5eb0e387b15c8278bb4e0d89ba1d`，license-id `android-sdk-license`。本机实际SDK的 `LicenseType.value` 使用 `TrimStringAdapter`：去除换行缩进、将单换行变空格、压缩多空格并trim，再由 `License.getLicenseHash()`计算UTF8 SHA1。对当前官方文本按该实际算法得到的hash精确为已有 `24333...`，所以许可已覆盖；只对raw XML或普通trim做hash会误报不匹配。没有追加或伪造许可接受记录；父代理在确认同一既有许可后实际完成官方NDK安装，随后按同样原则安装platform36/build-tools36。额外大型工具只放隔离F盘SDK，不改C盘共享SDK；如果未来出现不匹配的新许可，必须停止并由用户明确决定，不能沿用本次旧许可结论。

初试 Gradle8.14/AGP8.11.1 被 Flutter3.50 的最低版本校验拒绝，未跳过校验。随后官方SHA校验的 Gradle9.3.1（137,037,885 bytes）暴露了下述符号链接回归；最终 wrapper 由父代理改为 Flutter3.50 官方默认/支持的 **Gradle9.5.0 bin**，官方 SHA-256：`553c78f50dafcd54d65b9a444649057857469edf836431389695608536d6b746`，wrapper 自动校验。使用 AGP9.1.1、Java-only Android 入口，不加 Kotlin app 插件；NDK作为官方构建依赖已显式安装，并非本壳新增自写C/C++业务实现。缓存 Android engine artifacts 约843,842,181 bytes，不含复用的 Dart；历史Gradle缓存由本轮诊断保留，不重复下载同版本。

## 隔离环境与命令

[android.ps1](../tools/package/android.ps1) 准备/检查 F 盘独立路径、锁定现有许可组件、pub/analyze/test、仅构建 debug APK，输出 SHA-256，最后恢复进程环境并检查父 Dart exe 未变化。**脚本是否能在当前宿主执行取决于策略；不要修改 ExecutionPolicy 或通过换壳绕过拒绝。** 本轮宿主 AuthorizationManager 拒绝脚本，已记录；语法解析单独检查通过。

脚本参数包含 `-PrepareSdk`（仅拷原来已安装的SDK34基础组件/许可，不下载新增依赖）、`-Target android-arm64|android-x64`、`-Version`（默认0.1.0）、`-WorkspaceRoot`（可显式传入批准的 ASCII 路径）、`-SkipTests`。预检查要求隔离SDK已具有platform36、build-tools36和NDK28.2.13676358；缺失时明确报错并停止，不由脚本安装。脚本不安装Flutter、不接受许可、不改系统PATH、共享SDK或防火墙。

可在正常允许脚本的本机执行：

```powershell
.\tools\package\android.ps1 -PrepareSdk -Target android-arm64
```

当脚本执行被宿主拒绝时，不重试脚本；在获准的工作目录内使用直接 `flutter.bat` 命令，环境**仅当前进程**：

```powershell
$root = 'F:\zaizuo-mobile-probe' # 本轮明确许可的ASCII junction，非长期系统设置
$env:JAVA_HOME = 'C:\Program Files\Java\jdk-17'
$env:ANDROID_HOME = "$root\.local\android-sdk"
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:PUB_CACHE = "$root\.local\pub-cache"
$env:GRADLE_USER_HOME = "$root\.local\gradle"
$env:TEMP = "$root\.local\temp"
$env:TMP = $env:TEMP
$env:APPDATA = "$root\.local\flutter-user"
$env:LOCALAPPDATA = $env:APPDATA
$env:USERPROFILE = $env:APPDATA
$env:HOME = $env:USERPROFILE
$env:CI = 'true'
$env:DART_SUPPRESS_ANALYTICS = 'true'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"
# 工作目录 apps/mobile_probe
..\..\.local\flutter\bin\flutter.bat pub get
..\..\.local\flutter\bin\flutter.bat analyze
..\..\.local\flutter\bin\flutter.bat test --reporter expanded
..\..\.local\flutter\bin\flutter.bat build apk --debug --target-platform android-arm64 --no-pub
```

本轮 native `impellerc` 对中文绝对路径 include 处理有缺陷，原目录 shader 编译失败。经父代理明确许可，临时 `F:\zaizuo-mobile-probe` junction 指向工作区，避免复制仓库/SDK。创建前确认不存在，父代理接手诊断/构建期间保留，不在后台 Gradle 仍运行时移除；最终应验证 Target/LinkType 后只 `rmdir` junction 本身，禁止递归删除实际工作区。其他机器若路径全 ASCII，无需此临时别名。

这不是绕过文件权限：原中文路径的具体错误是 shader include 找不到已有的 `flutter/runtime_effect.glsl`。转成 ASCII junction 后 shader/Flutter测试通过，但 Gradle9.3.1 的 Kotlin DSL 受 [Gradle官方 #36483：Symbolic links are completely broken with Gradle9.2.0+](https://github.com/gradle/gradle/issues/36483) 影响。官方记录该回归在9.4修复；本机 `javap` 也证明生成 `Settings_gradle` 仅有 `(Settings)` 构造器，而 `Program.execute` 调用 `(KotlinScriptHost, Settings)`。重编同版本cache无效，故之前“旧cache污染”的初步猜测已被排除；升级至支持矩阵内9.5是使用官方修复，不修改Flutter源码或跳过validator。

## 输出与安装

本轮已实际构建成功（`flutter build apk --debug --target-platform android-arm64 --no-pub`，exit0），并复制核对最终产物：

- [Android arm64 debug/internal APK](../dist/packages/zaizuo-mobile-probe-0.1.0-android-arm64-debug.apk)
- [SHA-256 校验文件](../dist/packages/zaizuo-mobile-probe-0.1.0-android-arm64-debug.apk.sha256)

原构建产物位于应用目录 `build/app/outputs/flutter-apk/app-debug.apk`；最终分发文件与原文件 SHA-256 精确一致。构建脚本统一输出到 `dist/packages/`，默认版本0.1.0，不覆盖已有同名交付。

这是 Android 自动 debug/internal 签名，不是正式发行签名、没有 Play 签名/升级链承诺。真机安装需用户自行明确允许内部测试包，可用受信 ADB `adb install -r <APK>` 或手工打开 APK；本轮不替用户启用开发者选项/USB调试，不改手机安全设置，不自动安装到用户设备。

验收顺序：安装→启动确认“非完整 IM / Android Git未实现”→初始化测试 profile→内置 fixture PASS→系统选择无敏感图片 PASS→退出再开→卸载清除。还需 Android 版本、arm64/x64、选择器取消/Activity重建、低内存/耗时、恶意provider等独立验收。

## 本轮产物核验（APK已构建；未做真机安装/启动验收）

以下来自**最终APK实物**的只读 `aapt2 dump badging/permissions/xmltree`、`apksigner verify --verbose --print-certs`、ZIP目录及SHA-256检查，不是根据源码推断：

| 核验项 | 实际结果 |
| --- | --- |
| 文件大小 | **74,201,510 bytes**（约70.76MiB） |
| SHA-256 | `3cad4506f6f8eb61acd6770a677b5bf6ddd31199e0c494c217229ffda6a40f45` |
| 包名 | `dev.zaizuo.zaizuo_mobile_probe` |
| 版本 / versionCode | `0.1.0` / `1` |
| 应用label / 入口 | `在座 · 验证壳` / `dev.zaizuo.zaizuo_mobile_probe.MainActivity` |
| SDK | min24 / target34 / compile36 |
| Native ABI | **仅 `arm64-v8a`**；包含 `libflutter.so` 和调试验证层SO，不是x64/32位包 |
| 权限 | 仅自动生成的本应用 `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`（signature级）；**无 INTERNET、相册/存储、相机权限** |
| 备份/明文网络 | merged manifest确认 `allowBackup=false`、`fullBackupContent=false`、`usesCleartextTraffic=false` |
| 调试属性 | `debuggable=true`，仅内部验证 |
| 签名 | `apksigner verify` exit0；APK v2验证通过，单签名；v1/v3/v3.1/v4未启用，非SourceStamp |
| 证书 | `C=US, O=Android, CN=Android Debug`，RSA2048；证书SHA-256 `0847a82c8a867223e1f2012eba15ee5cc551b017755f882fda2d0297c067dee6` |
| ZIP检查 | 144条目，仅arm64 native目录；内置fixture `assets/flutter_assets/assets/probe.png`；未发现keybox/factor/recovery/password/keystore/私钥/日志/本机构建配置等敏感文件名 |
| 最终复制核对 | `dist/packages/` APK与原构建APK字节hash一致，旁置校验文件一致 |

ZIP文件名筛查不是完整二进制秘密扫描；debug包包含Dart/JIT测试运行所需的编译资产，不应承载生产账户。AndroidX自动合并的ProfileInstallReceiver受系统 `android.permission.DUMP` 保护，非本壳申请该权限。**签名验证和manifest读取证明包可被Android工具识别，不证明已经在设备上安装、启动或正确处理系统选择器。**

## 本轮构建与测试记录

- 浅克隆与Android precache成功；JDK17与F盘隔离SDK已准备。父代理安装NDK28.2.13676358、platform36 revision2、build-tools36.0.0成功，已读取各source.properties确认版本；没有接受新许可，没有修改共享C盘Android SDK。
- `dart format` 四个 Dart 文件无变更；`flutter analyze` 实跑无问题；`flutter test --reporter expanded` **3/3 通过**，包含真实 PreferredImageEncoder lossless WebP、密文落盘/解密/错误钥匙拒绝、profile 重开和限额，以及 Widget 明确能力缺口。测试数据目录解析回真实路径，以遵守 core 拒绝附件路径符号链接的安全检查，而不是取消该检查。
- **APK已由父代理以官方Gradle9.5.0/AGP9.1.1、NDK28.2/compileSdk36配置实际构建成功并完成上述产物核验。** 初期Gradle8.14最低版本拒绝、9.3.1符号链接回归、NDK缺失与build-tools36要求均已解决，不再列为当前阻塞。没有降低validator、没有新增许可hash；这份产物是本机图片/资料验证壳，不是完整IM Android交付。
- 已解决的9.3.1历史故障日志保留在 `.local/android-build-diagnostics/last-build-failure.log`，完整栈在 `.local/android-build-diagnostics/loader-stacktrace.log`；原始完整栈见 `.local/gradle/daemon/9.3.1/daemon-55492.out.log:166–182,359+`。父代理另行保留9.5的NDK/build-tools历史错误及最终exit0构建回执。最终打包已通过，但设备上的Activity/ContentProvider交互、真机图片编解码和生命周期仍需实机验收。
- 本机脚本初次被 AuthorizationManager 拒绝，已保留 `android.ps1` **语法解析0错误**，没有声称整份脚本执行通过。最终验证和构建均为显式环境下直接native Flutter命令；不改策略。早先子进程尝试已按父代理指令立即终止，未作为通过证据。
- 父 `.local/dart-sdk/bin/dart.exe` SHA-256 已核对仍为 `df42eb0c168858701f584615f90ee2a4b3d743a8a6dfd44036d38c4d898feb71`，与构建前一致。最终构建、验签、Flutter analyze/3项测试结束并确认无相关Gradle/Dart进程后，已核对LinkType/Target，仅移除临时 `F:\zaizuo-mobile-probe` workspace junction本身；真实工作区及产物保留。未来中文路径重建需按上述方法重新建立获准的临时别名，不能假设别名仍在。Flutter cache 的同revision Dart复用 junction仍保留，禁止自更新替换。
- 没有真机/模拟器安装或启动验收；一次只读ADB设备检查也因系统TEMP日志不可写而失败，未据此尝试调整系统或手机配置。该壳不能替代完整IM、Android Git和跨机图片收发的验收。
