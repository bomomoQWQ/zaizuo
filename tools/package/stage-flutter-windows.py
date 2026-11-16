#!/usr/bin/env python3
"""只打包已完成的 Windows Release；不构建、不运行应用、不读取用户资料。

python tools/package/stage-flutter-windows.py --version ui-test9 \
    --build-label ui-test9 [--source-ref FULL_COMMIT] [--project-root auto]

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
