#!/usr/bin/env python3
"""只打包已完成的 Windows Release；不构建、不运行应用、不读取用户资料。

python tools/package/stage-flutter-windows.py --version ui-test10 \
    --build-label ui-test10 [--source-ref FULL_COMMIT] [--project-root auto]

输出 dist/packages/zaizuo-client-VERSION-windows-x64{/, .zip, .zip.sha256}。
拒绝覆盖旧输出；失败可能留下新的不完整输出，必须换版本或人工核查。
调用者必须先完成构建并停止改动 Release。SHA 验证字节一致性，不能证明
AOT 中的 build-label 或对应源码语义；SOURCE.md 明确保留这个边界。
仅用 Python 标准库；不会读取 APPDATA、Git 凭据或访问网络。
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tempfile
import zipfile

RELEASE = Path("apps/mobile_probe/build/windows/x64/runner/Release")
# 显式固定当前客户端的运行时，不用 *.dll / 整个 Release 递归复制。
RUNTIME_FILES = (
    "zaizuo_mobile_probe.exe", "flutter_windows.dll", "dartjni.dll",
    "git2dart_binaries_plugin.dll", "libcrypto-3-x64.dll", "libgit2.dll",
    "libssh2.dll", "libssl-3-x64.dll", "native_assets.json",
)
DOCUMENTS = {
    "LICENSE": "LICENSE", "NOTICE": "NOTICE",
    "docs/测试前端.md": "TESTING.md",
    "docs/前端自测记录.md": "SELF-TEST.md",
}
SAFE_LABEL = re.compile(r"[A-Za-z0-9][A-Za-z0-9.+_-]{0,79}\Z")
COMMIT = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
FORBIDDEN = {
    ".git", ".ssh", ".env", "zaizuo-data", "profile", "git-credentials",
    "unlock.factor", "local-private.json", "account.keybox", "recovery.txt",
    "events", "state.enc", "id_rsa", "id_ed25519",
}
RESERVED = {"con", "prn", "aux", "nul"} | {
    f"{stem}{n}" for stem in ("com", "lpt") for n in range(1, 10)
}
SOURCE_REPOSITORY = "https://github.com/bomomoQWQ/zaizuo"
PUBLIC_CA = ("packages", "git2dart_binaries", "assets", "certs", "cacert.pem")
GENERATED_FILES = ("BUILD.json", "SOURCE.md", "README.md", "verify-and-start.ps1", "start-verified.cmd")
VERIFY_FAILURE = "校验失败：程序包文件缺失、被替换或清单无效；未启动在座。请重新解压完整新包，勿覆盖 data。"


class PackagingError(Exception):
    """只带固定诊断码，不能夹带主机路径、文件内容或子进程输出。"""


def require(condition: bool, code: str) -> None:
    if not condition:
        raise PackagingError(code)


def absolute(path: Path) -> Path:
    # 不 resolve()：先检查每级 lstat，不能先跟随链接。
    return Path(os.path.abspath(path))


def checked(path: Path, *, directory: bool = False) -> os.stat_result:
    path = absolute(path)
    for parent in (*reversed(path.parents), path):
        try:
            info = parent.lstat()
        except OSError:
            raise PackagingError("required_input_missing") from None
        require(not stat.S_ISLNK(info.st_mode) and not (
            getattr(info, "st_file_attributes", 0) & 0x400
        ), "links_or_reparse_points_forbidden")
        if parent != path:
            require(stat.S_ISDIR(info.st_mode), "input_parent_not_directory")
    require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode),
            "input_not_regular")
    return info


def make_directories(path: Path) -> None:
    path = absolute(path)
    if os.path.lexists(path):
        checked(path, directory=True)
        return
    make_directories(path.parent)
    path.mkdir()
    checked(path, directory=True)


def safe_component(name: str, *, public_ca: bool = False) -> None:
    folded = name.casefold()
    require(bool(name) and name not in {".", ".."} and
            not any(ord(c) < 32 or c in '<>:"/\\|?*' for c in name) and
            not name.endswith((" ", ".")) and
            folded.split(".")[0] not in RESERVED, "unsafe_entry_name")
    require(folded not in FORBIDDEN and not folded.startswith(".env.") and
            (public_ca or not folded.endswith((".pem", ".key", ".keybox", ".p12", ".pfx"))),
            "private_material_name_forbidden")


def safe_relative(name: str) -> None:
    require(not PurePosixPath(name).is_absolute() and "\\" not in name,
            "unsafe_relative_path")
    parts = tuple(name.split("/"))
    for index, component in enumerate(parts):
        safe_component(component, public_ca=index == len(parts) - 1 and
                       parts[-len(PUBLIC_CA):] == PUBLIC_CA)


def tree_files(root: Path) -> dict[str, Path]:
    checked(root, directory=True)
    result: dict[str, Path] = {}
    folded: set[str] = set()

    def walk(directory: Path) -> None:
        checked(directory, directory=True)
        for item in sorted(directory.iterdir(), key=lambda p: p.name):
            safe_relative(item.relative_to(root).as_posix())
            info = item.lstat()
            require(not stat.S_ISLNK(info.st_mode) and not (
                getattr(info, "st_file_attributes", 0) & 0x400
            ), "links_or_reparse_points_forbidden")
            if stat.S_ISDIR(info.st_mode):
                walk(item)
            else:
                checked(item)
                relative = item.relative_to(root).as_posix()
                require(relative.casefold() not in folded, "case_colliding_entries")
                folded.add(relative.casefold())
                result[relative] = item
    walk(root)
    return result


def digest_stream(stream) -> str:
    digest = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
    return digest.hexdigest()


def file_hash(path: Path) -> str:
    before = checked(path)
    with path.open("rb") as source:
        opened = os.fstat(source.fileno())
        require((before.st_dev, before.st_ino) == (opened.st_dev, opened.st_ino),
                "input_changed_during_read")
        value = digest_stream(source)
        after = os.fstat(source.fileno())
    current = checked(path)
    require((before.st_size, before.st_mtime_ns, before.st_ino) ==
            (after.st_size, after.st_mtime_ns, after.st_ino) ==
            (current.st_size, current.st_mtime_ns, current.st_ino),
            "input_changed_during_read")
    return value


def collect_sources(root: Path) -> dict[str, Path]:
    checked(root, directory=True)
    release = root / RELEASE
    checked(release, directory=True)
    # 只查看 Release 顶层名称；不进入 zaizuo-data、profile 等旁目录。
    for entry in release.iterdir():
        if entry.suffix.casefold() in {".exe", ".dll"}:
            require(entry.name in RUNTIME_FILES, "unsupported_runtime_binary")
    sources = {name: release / name for name in RUNTIME_FILES}
    data = release / "data"
    checked(data, directory=True)
    require({p.name for p in data.iterdir()} ==
            {"app.so", "icudtl.dat", "flutter_assets"}, "unexpected_data_entry")
    sources.update({"data/app.so": data / "app.so", "data/icudtl.dat": data / "icudtl.dat"})
    assets = tree_files(data / "flutter_assets")
    require(bool(assets), "flutter_assets_empty")
    sources.update({f"data/flutter_assets/{name}": path for name, path in assets.items()})
    sources.update({target: root / source for source, target in DOCUMENTS.items()})
    # Flutter 标准缓存 windows-x64 是 Release 引擎；绝不回退 debug。
    engine = root / ".local/flutter/bin/cache/artifacts/engine"
    for variant in ("windows-x64-release", "windows-x64"):
        candidate = engine / variant / "LICENSE.windows_flutter.md"
        if os.path.lexists(candidate):
            sources["LICENSE.windows_flutter.md"] = candidate
            break
    require("LICENSE.windows_flutter.md" in sources, "flutter_release_license_missing")
    for name, path in sources.items():
        safe_relative(name)
        checked(path)
        if not name.startswith("data/flutter_assets/"):
            require(path.stat().st_size > 0, "required_input_empty")
    ca = sources.get("data/flutter_assets/" + "/".join(PUBLIC_CA))
    if ca is not None:
        # 此固定路径是公共 TLS CA 包，不是私钥；拒绝夹入私钥 PEM 块。
        require(0 < ca.stat().st_size <= 4 * 1024 * 1024, "public_ca_invalid")
        pem = ca.read_bytes()
        require(b"-----BEGIN CERTIFICATE-----" in pem and b"PRIVATE KEY" not in pem,
                "public_ca_invalid")
    return dict(sorted(sources.items()))


def git_provenance(root: Path, explicit: str | None) -> tuple[str, str]:
    if explicit is not None:
        require(bool(COMMIT.fullmatch(explicit)), "source_ref_requires_full_commit")
        return explicit, "caller-supplied-not-verified"
    # 本地只读 Git 元数据；禁外部 diff/textconv/fsmonitor 与继承 Git 配置。
    env = {k: v for k, v in os.environ.items()
           if not k.upper().startswith(("GIT_", "GCM_"))}
    env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_CONFIG_SYSTEM": os.devnull, "GIT_OPTIONAL_LOCKS": "0"})
    prefix = ["git", "--no-pager", "-c", "core.fsmonitor=false", "-C", str(root)]
    try:
        head = subprocess.run(prefix + ["rev-parse", "--verify", "HEAD"], env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              check=False, timeout=15)
        commit = head.stdout.decode("ascii", errors="replace").strip()
        require(head.returncode == 0 and bool(COMMIT.fullmatch(commit)),
                "source_ref_unavailable_supply_full_commit")
        dirty = subprocess.run(prefix + ["diff", "--quiet", "--no-ext-diff",
                                        "--no-textconv", "HEAD", "--"], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               check=False, timeout=15)
        require(dirty.returncode in (0, 1), "source_state_unavailable")
    except (OSError, subprocess.SubprocessError):
        raise PackagingError("source_ref_unavailable_supply_full_commit") from None
    return commit, "tracked-dirty" if dirty.returncode else "tracked-clean-untracked-not-inspected"


def copy_verified(source: Path, destination: Path) -> str:
    before = file_hash(source)
    make_directories(destination.parent)
    with source.open("rb") as incoming, destination.open("xb") as outgoing:
        for chunk in iter(lambda: incoming.read(1024 * 1024), b""):
            outgoing.write(chunk)
    require(file_hash(source) == before == file_hash(destination), "copied_source_mismatch")
    return before


def write_new(path: Path, text: str) -> None:
    with path.open("x", encoding="utf-8", newline="\n") as output:
        output.write(text)


def windows_entrypoints(expected_files: list[str]) -> tuple[str, str]:
    """固定本包文件白名单；不枚举未知目录，也不读取/修改私人资料目录。"""
    require(len(expected_files) == len(set(expected_files)), "duplicate_launcher_entry")
    for name in expected_files:
        safe_relative(name)
    # PowerShell 单引号字面量：文件名中的 ' 必须成对转义，不能插入脚本。
    allowlist = "\n".join("    '" + name.replace("'", "''") + "'" for name in sorted(expected_files))
    ps1 = r'''# 在座：只验证本包白名单文件；不扫描或读取私人账号目录。
[CmdletBinding()]
param([string]$DataDirectory, [switch]$VerifyOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-PackageEntry {
    param([string]$Root, [string]$Relative, [bool]$Directory = $false)
    # Relative 已经通过白名单/路径语法校验。逐级查属性，不遍历目录。
    $current = $Root
    $rootItem = Get-Item -LiteralPath $current -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or
        (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw 'invalid-package-root'
    }
    $parts = $Relative.Split([char]'/')
    for ($index = 0; $index -lt $parts.Length; $index++) {
        $current = [IO.Path]::Combine($current, $parts[$index])
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'linked-package-entry'
        }
        $wantDirectory = ($index -lt ($parts.Length - 1)) -or $Directory
        if ([bool]$item.PSIsContainer -ne $wantDirectory -or
            (-not $wantDirectory -and $item -isnot [IO.FileInfo])) {
            throw 'invalid-package-entry'
        }
    }
    return $current
}

function Test-PackageIntegrity {
    param([string]$Root)
    # 此列表由打包时的 source set + 固定 generated files 生成；绝不全盘扫描。
    $expectedFiles = @(
__ALLOWLIST__
    )
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $expectedFiles) { [void]$allowed.Add($entry) }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $manifest = Assert-PackageEntry -Root $Root -Relative 'SHA256SUMS'
    foreach ($line in [IO.File]::ReadAllLines($manifest, [Text.Encoding]::UTF8)) {
        if ($line -cnotmatch '^([0-9a-f]{64})  (.+)$') { throw 'invalid-manifest' }
        $hash = $Matches[1]
        $relative = $Matches[2]
        if ($relative.Contains('\') -or $relative.Contains(':') -or
            [IO.Path]::IsPathRooted($relative)) { throw 'unsafe-manifest-path' }
        foreach ($part in $relative.Split([char]'/')) {
            if ([string]::IsNullOrEmpty($part) -or $part -eq '.' -or $part -eq '..' -or
                $part.EndsWith(' ') -or $part.EndsWith('.') -or
                $part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
                throw 'unsafe-manifest-path'
            }
        }
        if (-not $allowed.Contains($relative) -or -not $seen.Add($relative)) {
            throw 'unexpected-or-duplicate-manifest-path'
        }
        $path = Assert-PackageEntry -Root $Root -Relative $relative
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($actual -ine $hash) { throw 'package-hash-mismatch' }
    }
    if ($seen.Count -ne $allowed.Count) { throw 'incomplete-manifest' }
}

try {
    if ($PSBoundParameters.ContainsKey('DataDirectory')) {
        # 仅检查参数语法，不 Test-Path、不建目录、不读账号/令牌。拒绝 C:relative / \relative。
        if ([string]::IsNullOrWhiteSpace($DataDirectory) -or
            $DataDirectory -cnotmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$))' -or
            $DataDirectory -match '[\x00-\x1f"<>|?*]' -or
            $DataDirectory.StartsWith('\\?\') -or $DataDirectory.StartsWith('\\.\')) {
            throw 'absolute-data-directory-required'
        }
    }
    Test-PackageIntegrity -Root $PSScriptRoot
} catch {
    [Console]::Error.WriteLine('__VERIFY_FAILURE__')
    exit 1
}

# 可供静态验包；不会运行客户端，也不访问 DataDirectory。
if ($VerifyOnly) { exit 0 }

# 在校验全部通过前绝不启动。& 按单一参数传递含空格/中文的绝对目录，保留前台终端。
$executable = [IO.Path]::Combine($PSScriptRoot, 'zaizuo_mobile_probe.exe')
try {
    if ($PSBoundParameters.ContainsKey('DataDirectory')) {
        & $executable "--data-dir=$DataDirectory"
    } else {
        # 不附加 data-dir；保留应用原有默认启动行为，不由本脚本创建或迁移 profile。
        & $executable
    }
    if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }
} catch {
    [Console]::Error.WriteLine('启动失败：无法运行已校验的在座客户端。')
    exit 1
}
'''.replace("__ALLOWLIST__", allowlist).replace("__VERIFY_FAILURE__", VERIFY_FAILURE)
    # ASCII 文件名/内容兼容 CMD；不要执行策略绕过、提权或读取 PowerShell profile。
    cmd = r'''@echo off
setlocal
where pwsh.exe >nul 2>nul
if errorlevel 1 goto windows_powershell
pwsh.exe -NoLogo -NoProfile -File "%~dp0verify-and-start.ps1" %*
exit /b %errorlevel%
:windows_powershell
where powershell.exe >nul 2>nul
if errorlevel 1 goto missing_powershell
powershell.exe -NoLogo -NoProfile -File "%~dp0verify-and-start.ps1" %*
exit /b %errorlevel%
:missing_powershell
echo PowerShell was not found. Install PowerShell, then retry.
exit /b 1
'''
    return ps1, cmd


def package_readme(version: str) -> str:
    return f'''# 在座 {version} Windows 测试包：先校验，再启动

## 全新解压与启动

1. 把整个 ZIP 解压到一个全新的目录；不要把新旧包覆盖合并。
2. 双击 `start-verified.cmd`，或在 PowerShell 中运行：
   `& '.\\verify-and-start.ps1'`
   仅静态核验、不运行客户端：`& '.\\verify-and-start.ps1' -VerifyOnly`。
   CMD 优先调用 pwsh、否则 Windows PowerShell，均使用 `-NoProfile -File`。
   不读取 PowerShell profile、不提权、不绕过执行策略；本机策略可能在脚本执行前拦截。
   若被拦截，不修改执行策略，也不动态加载脚本绕过；请先人工核对发布的 ZIP 摘要及
   SHA256SUMS，或由发布者的打包工具做静态核验，再直接运行 `zaizuo_mobile_probe.exe`。
   直接运行 EXE 不会自动校验；这不是校验脚本的自动回退，不能当作已执行脚本校验。
3. 启动前按 SHA256SUMS 核对本包白名单内全部文件的存在性、非链接属性及 SHA-256；
   缺失、替换、哈希不符、重复/越界清单项均报固定中文错误并退出，不启动客户端。
   只检查清单白名单，不枚举旁边目录，不读取 APPDATA、token 或私人资料。
4. 不传参数时，应用保持其原有默认启动行为；校验器不创建、修改或迁移 profile。
   校验字节一致性不等于签名认证；它不能证明发布者身份、AOT 对应源码或运行中的窗口版本。
   如脚本与清单同时被替换，不能依靠包内自校验辨认，请另行核验发布的 ZIP 摘要。

## 升级规则：data 不是账号资料

- `data` 是程序代码和运行资源（含 `data/app.so`），必须与当前完整新包配套。
  **不能把旧 test4/test9 的 data 或 app.so 覆盖到新包**；否则仍可能运行旧代码，校验器会拒绝启动。
- `zaizuo-data` 是私人账号目录，**不要进包**，不要复制进程序 `data`；不要上传账号目录、密钥或令牌。
- 要继续使用旧 test9 的私人目录，可在 PowerShell 中显式传入旧目录的绝对路径，例如：
  `& '.\\verify-and-start.ps1' -DataDirectory 'D:\\old-test9\\zaizuo-data'`
  参数以一个 `--data-dir=绝对路径` 传给客户端；可含空格/中文，不移动、不复制、不共享旧目录。
  此示例路径须由用户自己替换；校验器不访问或创建目标目录，客户端启动后仍会正常使用所选资料。
- CMD 会透传参数；含复杂字符时推荐直接在 PowerShell 使用上述 `-DataDirectory` 方式。
  本包不写死任何旧目录，也不自动生成指向私人目录的本机快捷脚本。
- 同一个私人目录不能多开：先正常退出所有使用该目录的旧客户端，再启动新版本。
  不要让两个进程同时读写同一目录；保留旧目录并不表示可让新旧客户端并发共享。

## 包内容与验证边界

BUILD.json 记录打包声明、来源和复制文件哈希；SOURCE.md 记录对应源码与许可边界。
SHA256SUMS 覆盖所有运行时、公开文档、BUILD.json、SOURCE.md、本说明和两个启动脚本，
不包含自身。打包时还比较 source → stage → ZIP → 临时解压树，未运行真实客户端。
'''


def verify_package(stage: Path, archive: Path, sources: dict[str, Path],
                   copied_hashes: dict[str, str]) -> dict[str, str]:
    """核对当前 source → stage → ZIP → 新临时解压树，全部逐文件 exact。"""
    staged = tree_files(stage)
    require("SHA256SUMS" in staged, "checksum_manifest_missing")
    hashes: dict[str, str] = {}
    for line in staged["SHA256SUMS"].read_text(encoding="utf-8").splitlines():
        require(len(line) > 66 and line[64:66] == "  " and
                bool(re.fullmatch(r"[0-9a-f]{64}", line[:64])), "checksum_manifest_invalid")
        name = line[66:]
        safe_relative(name)
        require(name not in hashes and name != "SHA256SUMS", "checksum_manifest_invalid")
        hashes[name] = line[:64]
    require(set(staged) == set(hashes) | {"SHA256SUMS"}, "stage_file_set_mismatch")
    for name, value in hashes.items():
        require(file_hash(staged[name]) == value, "stage_hash_mismatch")
    require(set(sources) == set(copied_hashes), "source_file_set_mismatch")
    for name, source in sources.items():
        require(name in hashes and file_hash(source) == copied_hashes[name] == hashes[name],
                "source_hash_mismatch")
    hashes["SHA256SUMS"] = file_hash(staged["SHA256SUMS"])
    checked(archive)
    checked(stage.parent, directory=True)
    # 临时目录只含我们刚验证的 ZIP；从不解压到旧的用户运行目录。
    with tempfile.TemporaryDirectory(prefix=f".{stage.name}-verify-", dir=stage.parent) as tmp:
        extracted = absolute(Path(tmp))
        require(extracted.parent == absolute(stage.parent) and
                extracted.name.startswith(f".{stage.name}-verify-"), "unsafe_verify_directory")
        checked(extracted, directory=True)
        try:
            with zipfile.ZipFile(archive) as bundle:
                infos = bundle.infolist()
                expected = {f"{stage.name}/{name}" for name in hashes}
                require(len(infos) == len(expected) and {i.filename for i in infos} == expected,
                        "archive_file_set_mismatch")
                for info in infos:
                    safe_relative(info.filename)
                    mode = info.external_attr >> 16
                    require(not info.is_dir() and not stat.S_ISLNK(mode), "archive_link_forbidden")
                    name = info.filename[len(stage.name) + 1:]
                    require(info.file_size == staged[name].stat().st_size, "archive_size_mismatch")
                    target = extracted.joinpath(*PurePosixPath(info.filename).parts)
                    make_directories(target.parent)
                    with bundle.open(info) as incoming, target.open("xb") as outgoing:
                        for chunk in iter(lambda: incoming.read(1024 * 1024), b""):
                            outgoing.write(chunk)
                    require(file_hash(target) == hashes[name], "archive_hash_mismatch")
            unpacked = tree_files(extracted / stage.name)
            require(set(unpacked) == set(hashes), "extracted_file_set_mismatch")
            for name, path in unpacked.items():
                require(file_hash(path) == hashes[name] == file_hash(staged[name]),
                        "extracted_hash_mismatch")
        except (zipfile.BadZipFile, RuntimeError):
            raise PackagingError("archive_invalid") from None
        # TemporaryDirectory 退出时只清理由本函数创建且已核对绝对位置的目录。
        checked(extracted, directory=True)
    return hashes


def stage_windows(root: Path, version: str, build_label: str,
                  source_ref: str | None = None) -> dict[str, object]:
    require(bool(SAFE_LABEL.fullmatch(version)) and bool(SAFE_LABEL.fullmatch(build_label)),
            "unsafe_version_or_build_label")
    root = absolute(root)
    checked(root, directory=True)
    name = f"zaizuo-client-{version}-windows-x64"
    output = root / "dist/packages"
    stage, archive = output / name, output / f"{name}.zip"
    checksum = output / f"{name}.zip.sha256"
    require(not any(os.path.lexists(p) for p in (stage, archive, checksum)), "output_already_exists")
    sources = collect_sources(root)
    commit, worktree = git_provenance(root, source_ref)
    make_directories(output)
    # mkdir 和 xb/x 都不覆盖；即使并发重复发布也必须有一方失败。
    stage.mkdir()
    copied_hashes = {relative: copy_verified(source, stage / relative)
                     for relative, source in sources.items()}
    metadata = {
        "schema": 1, "project": "zaizuo", "version": version,
        "build_label": build_label, "build_label_verification": "caller-asserted-not-aot-verified",
        "platform": "windows-x64", "created_utc": datetime.now(timezone.utc).isoformat(),
        "build_method": "stage-existing-flutter-release", "compilation_performed": False,
        "runtime_or_network_test_performed": False, "source_repository": SOURCE_REPOSITORY,
        "source_ref": commit, "source_worktree": worktree,
        "source_release": RELEASE.as_posix(), "project_license": "AGPL-3.0-only",
        "app_so_sha256": copied_hashes["data/app.so"],
        "copied_files": {name: {"sha256": digest, "bytes": (stage / name).stat().st_size}
                         for name, digest in copied_hashes.items()},
    }
    write_new(stage / "BUILD.json", json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    write_new(stage / "SOURCE.md", f"""# 对应源码 / Corresponding Source

- Project license: AGPL-3.0-only; see LICENSE and NOTICE.
- Source repository: {SOURCE_REPOSITORY}
- Source commit (publisher declaration): {commit}
- Source URL: {SOURCE_REPOSITORY}/tree/{commit}
- Source archive: {SOURCE_REPOSITORY}/archive/{commit}.tar.gz
- Local source state: {worktree}
- Package version: {version}; declared build label: {build_label}.

This script staged an existing Windows Flutter Release; it did not compile or run
it. Every copied source file, staged file and ZIP-extracted file was compared by
SHA-256. Hash equality does not prove the AOT was compiled from this source commit
or with the declared build label. The publisher must first build this exact source
and verify the runtime build label; uncommitted changes are not in the source URL.
The corresponding source must remain available at no additional charge; follow
AGPL sections 6 and 13 where applicable. Third-party notices retain their terms.
No private profile, Git credential or user data directory belongs in this package.
""")
    write_new(stage / "README.md", package_readme(version))
    expected_files = sorted(set(sources) | set(GENERATED_FILES))
    ps1, cmd = windows_entrypoints(expected_files)
    # Windows PowerShell 5.1 需要 BOM 才能可靠识别中文；CMD 保持 ASCII + CRLF。
    with (stage / "verify-and-start.ps1").open("x", encoding="utf-8-sig", newline="\r\n") as script:
        script.write(ps1)
    with (stage / "start-verified.cmd").open("x", encoding="ascii", newline="\r\n") as script:
        script.write(cmd)
    hashes = {name: file_hash(path) for name, path in tree_files(stage).items()}
    write_new(stage / "SHA256SUMS", "".join(f"{hashes[name]}  {name}\n" for name in sorted(hashes)))
    with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_DEFLATED, allowZip64=True) as bundle:
        for relative, path in tree_files(stage).items():
            checked(path)
            bundle.write(path, f"{name}/{relative}")
    require(collect_sources(root) == sources, "source_file_set_mismatch")
    verified = verify_package(stage, archive, sources, copied_hashes)
    archive_hash = file_hash(archive)
    write_new(checksum, f"{archive_hash}  {archive.name}\n")
    return {"stage": stage.relative_to(root).as_posix(),
            "archive": archive.relative_to(root).as_posix(),
            "sha256": archive_hash, "app_so_sha256": verified["data/app.so"],
            "verified_file_count": len(verified), "version": version,
            "build_label": build_label, "source_ref": commit}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-label", required=True)
    parser.add_argument("--source-ref", help="完整小写 commit；不填则只读本地 Git HEAD")
    parser.add_argument("--project-root", default="auto", help="默认由本脚本位置定位项目根")
    args = parser.parse_args(argv)
    root = Path(__file__).absolute().parents[2] if args.project_root == "auto" else Path(args.project_root)
    try:
        result = stage_windows(root, args.version, args.build_label, args.source_ref)
    except PackagingError as error:
        print(f"packaging_failed: {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError, zipfile.BadZipFile):
        # 不打印异常原文，避免输出宿主路径或不受控文件名。
        print("packaging_failed: local_io_or_archive_failure", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
