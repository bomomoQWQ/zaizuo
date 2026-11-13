# 嵌入 Git 原生材料与来源审计（2026-11-13）

## 范围与结论

本目录只覆盖项目 exact 锁定的 `git2dart 0.5.6`、`git2dart_binaries 1.14.1` 的 Android 四 ABI 原生库、Windows x64 DLL，以及包内 CA 数据。不是 Flutter/整个 APK 的完整 SBOM，也不是已完成的发布合规证明。未构建、未更改 pub cache、未下载 SDK 或编译产物；没有 Android 真机（本轮 ADB 设备为 0），不声称 Android HTTPS 或 Ubuntu 测试通过。

包根 MIT **不覆盖所有内含原生组件**。项目原创部分为 AGPL-3.0-only；第三方保留自己的许可。

## 锁包、版本和证据分级

- `git2dart 0.5.6` pub archive SHA256（本地 hosted-hashes 记录）：`bc4cec5b9c00048e52f269b14a0f89b4fb1a486aa538217a032cb9729ba26fa7`。
- `git2dart_binaries 1.14.1` pub archive SHA256（本地 hosted-hashes 记录，父任务已取得 archive）：`ff0440138a62830982d3298abbaf1acefec5178dba46d337fe8567d19a4b7015`。本轮没有重新下载归档或独立验证其签名。
- [native-manifest.json](<native-manifest.json>) 记录缓存中 **16 个 Android SO + 4 个 Windows DLL** 的实际 SHA256/size，20 个文件全部匹配包内 provenance。还记录两份 CA 的实际摘要。包内原始 sidecar 已逐份保存在 `evidence/`。
- provenance 一致声明：libgit2 **1.9.7**、libssh2 **1.11.1**、OpenSSL **3.0.15**、`source-build`。这属于供应者声明，不是独立可复现构建证明。包 CHANGELOG 的 1.14.0 条目声明更新 libgit2 至 1.9.7；1.14.1 条目主要改 Linux。
- [Android 真实链接及字符串](<evidence/android-linkage-strings.txt>)：四 ABI 都有 `libgit2 1.9.7`、`OpenSSL 3.0.15 3 Sep 2024`；**libssh2 字符串实际为 `SSH-2.0-libssh2_1.11.1_DEV`**，不能把 clean release 身份视为已独立验证。OpenSSL OID 中数字不是 zlib 版本。
- [Windows import 表](<evidence/windows-libgit2-imports.txt>) 明确导入 `WINHTTP.dll`、`libssh2.dll` 等系统 DLL；实际 HTTPS backend=winhttp/libgit2=1.9.7 是父任务运行时结果，本轮不冒充重测。

## 许可全文与可定位源码

| 组件 / 已知来源版本 | 许可材料 | 源码 / 原文来源 |
| --- | --- | --- |
| git2dart 0.5.6 | [MIT 全文](<licenses/git2dart-MIT.txt>)，含原作者版权 | [pub 版本](https://pub.dev/packages/git2dart/versions/0.5.6)、[upstream](https://github.com/DartGit-dev/git2dart)；全文直接来自锁包 LICENSE |
| git2dart_binaries 1.14.1 的包装代码 | [MIT 全文](<licenses/git2dart_binaries-MIT.txt>) | [pub 版本](https://pub.dev/packages/git2dart_binaries/versions/1.14.1)、[upstream](https://github.com/DartGit-dev/git2dart_binaries)；全文直接来自锁包 LICENSE |
| libgit2 1.9.7 | [完整 COPYING](<licenses/libgit2-COPYING.txt>)：GPL-2.0-only + 上游 linking exception，及上游整份第三方 notices | [v1.9.7 源码](https://github.com/libgit2/libgit2/tree/v1.9.7)、[原始 COPYING](https://raw.githubusercontent.com/libgit2/libgit2/v1.9.7/COPYING) |
| libssh2：sidecar 1.11.1 / 二进制 1.11.1_DEV | [BSD-3-Clause 全文](<licenses/libssh2-COPYING.txt>) | [声明版本源码](https://github.com/libssh2/libssh2/tree/libssh2-1.11.1)、[COPYING](https://raw.githubusercontent.com/libssh2/libssh2/libssh2-1.11.1/COPYING)；实际 commit/patch 仍待供应者证明 |
| OpenSSL 3.0.15（libssl/libcrypto） | [Apache-2.0 全文](<licenses/OpenSSL-LICENSE.txt>) | [源码 tag](https://github.com/openssl/openssl/tree/openssl-3.0.15)、[原始 LICENSE](https://raw.githubusercontent.com/openssl/openssl/openssl-3.0.15/LICENSE.txt)；版权归 OpenSSL Project Authors，具体文件保留各自 notices |
| CA PEM：包头标注 Mozilla 2025-11-04、mk-ca-bundle 1.29 | [MPL-2.0 全文，含 NSS 原始说明](<licenses/MPL-2.0.txt>) | [curl CA extraction 说明及历史下载](https://curl.se/docs/caextract.html) 明确 PEM 为 MPL-2.0；[2025-11-04 PEM](https://curl.se/ca/cacert-2025-11-04.pem)；精确 Mozilla certdata commit 未锁定 |
| Android 系统 libz.so / libc / libm / libdl | 非本包随附的独立 SO；zlib 许可文本同时保存在 libgit2 完整 COPYING 内 | 四 ABI 的 libgit2、libssh2 都 `DT_NEEDED libz.so`；系统实现/版本依运行设备，**未知，不猜** |
| libgit2 内嵌候选依赖 | 全份 COPYING 保守保留 PCRE2/BSD、zlib、SHA1 collision detection/MIT、wildmatch/Rich Salz、llhttp/MIT、RFC6234/BSD、ntlmclient/MIT、Unicode、LLVM、winhttp definitions/LGPL-2.1 等完整文本 | 同一 [libgit2 v1.9.7](https://github.com/libgit2/libgit2/tree/v1.9.7)；不是断言这些每一项都实际进入每个二进制，需最终构建配置/符号证据裁定 |

完整 COPYING 中出现的历史 OpenSSL 头文件许可与 LGPL notices 是 libgit2 自己的逐部件 notices；不能据此把实际 OpenSSL 3 库改标成旧 OpenSSL 许可，也不能删去 linking exception 而仅保留通用 GPL 文本。

This product includes software developed by Rich Salz.
This product includes cryptographic software written by Eric Young (eay@cryptsoft.com).
This product includes software developed by the OpenSSL Project for use in the OpenSSL Toolkit (http://www.openssl.org/).

## 构建脚本证据与边界

pub archive 不含 `.github/`；尝试 upstream `v1.14.1` 和 `1.14.1` 的 workflow raw URL 均为 404。读取了 [main workflow](https://raw.githubusercontent.com/DartGit-dev/git2dart_binaries/main/.github/workflows/build_package.yml)：变量为 1.9.7/1.11.1/3.0.15。保存的 [Android action 快照](<evidence/build-android-main.yml>)、[Windows action 快照](<evidence/build-windows-main.yml>) 分别来自 [Android raw](https://raw.githubusercontent.com/DartGit-dev/git2dart_binaries/main/.github/actions/build-android/action.yml)、[Windows raw](https://raw.githubusercontent.com/DartGit-dev/git2dart_binaries/main/.github/actions/build-windows/action.yml)。外部文件仅作数据保存，**未执行**。

Android 快照显式 `USE_HTTPS=OpenSSL`、`USE_SSH=libssh2`、`EXPERIMENTAL_SHA256=ON`、NDK r26d / API21；Windows 快照未显式指定 USE_HTTPS（实际 DLL 为 WinHTTP）。这些是 **2026-11-13 获取的 mutable main 快照**，并非归档对应提交的确定证明；不能以 main 取代发布 commit 证明。sidecar `source_ref` 只精确写了 OpenSSL tag，toolchain 是不透明摘要，不是完整编译日志。

## 内部 APK 打包交接 / 未闭环事项

1. 由父任务把本目录的 `licenses/` **全部全文**、本说明和 manifest 复制到应用许可 assets 并在 pubspec 声明（本轮不改 pubspec）。不要只复制包装包 MIT 或只提供外链；应用应提供可读入口。Flutter 自动 NOTICES 不能被假定已收录 native 全文。
2. 对最终 APK 的每个 `lib/<abi>/` 条目、CA asset 和许可 asset 重新清点/哈希；Gradle strip/ABI filter 可能改变 SO 摘要或集合。当前 manifest 是缓存原件清单，**不是 APK 内已验证清单**。
3. 向供应者取得与 archive 完全对应的源码 commit、补丁、CMake cache/配置、构建/安装脚本及完整依赖 notices，特别是 libssh2 `_DEV` 身份与 Windows 静态内嵌 zlib/PCRE2 等实际选择。本轮没有重建或证明二进制可复现。
4. libgit2 linking exception 允许组合链接，但不应被描述为免除所有 GPL 义务。对以共享库形式再分发的实际形态审查 GPLv2 §3 对应源码安排；上游 tag URL 是源码定位信息，**本清单不是有效三年书面 offer，也不是已经随 APK 提供完整 corresponding source**。源码交付方式及上游变更仍需发布方闭环。
5. CA PEM 源形式/转换脚本版本与精确 NSS certdata commit、MPL source availability 需要补齐；许可全文不等于已经闭环源码可用义务。包头记录 2025-11-04，不以今天的最新 CA 覆盖其身份；也未核验证书安全时效或浏览器 trust constraints（转换 PEM 不携带全部浏览器约束）。
6. 当前材料是内部测试包所需许可材料准备，**不是公开发布放行**。未审计全应用传递依赖/工具链 runtime，未声称所有第三方都 AGPL、MIT 或均已完整验证。
