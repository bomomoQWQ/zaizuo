#!/usr/bin/env bash
# 本机Linux原生编译/打包；不调用sudo、不安装依赖、不创建账号/服务、不改系统配置。
set -euo pipefail
umask 022
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
DART="$ROOT/.local/dart-sdk/bin/dart"
OUT="$ROOT/dist/packages"
VERSION=0.1.0-dev
SOURCE_REF=
DEB=auto
PUB_GET=1
SMOKE=1
usage() {
  printf '%s\n' 'usage: bash build-linux.sh [--dart /absolute/dart] [--out-dir DIR] [--version VERSION] [--source-ref TAG] [--deb auto|yes|no] [--skip-pub-get] [--skip-smoke]'
}
while (($#)); do
  case "$1" in
    --dart|--out-dir|--version|--source-ref|--deb)
      (($# >= 2)) || { usage >&2; exit 64; }
      case "$1" in --dart) DART=$2;; --out-dir) OUT=$2;; --version) VERSION=$2;; --source-ref) SOURCE_REF=$2;; --deb) DEB=$2;; esac
      shift 2;;
    --skip-pub-get) PUB_GET=0; shift;;
    --skip-smoke) SMOKE=0; shift;;
    -h|--help) usage; exit 0;;
    *) printf '未知参数：%s\n' "$1" >&2; usage >&2; exit 64;;
  esac
done
[[ $(uname -s) == Linux ]] || { printf '请在Linux本机运行，不伪装跨平台编译。\n' >&2; exit 1; }
[[ $VERSION =~ ^[0-9][0-9A-Za-z.+-]*$ ]] || { printf '无效版本字符串。\n' >&2; exit 64; }
[[ -n $SOURCE_REF ]] || SOURCE_REF="v$VERSION"
[[ $SOURCE_REF =~ ^v[0-9][0-9A-Za-z.+-]*$ ]] || { printf '无效源码版本标签。\n' >&2; exit 64; }
SOURCE_REPOSITORY=https://github.com/bomomoQWQ/zaizuo
SOURCE_URL="$SOURCE_REPOSITORY/tree/$SOURCE_REF"
SOURCE_ARCHIVE="$SOURCE_REPOSITORY/archive/refs/tags/$SOURCE_REF.tar.gz"
for notice in LICENSE NOTICE; do
  [[ -s "$ROOT/$notice" ]] || { printf '缺少项目根许可/声明：%s\n' "$ROOT/$notice" >&2; exit 1; }
done
[[ $DEB == auto || $DEB == yes || $DEB == no ]] || { usage >&2; exit 64; }
[[ -x $DART ]] || { printf 'Dart不可执行：%s\n' "$DART" >&2; exit 1; }
# 输出路径可以包含空格，不使用eval；构建中间目录永远留在仓库.local。
mkdir -p -- "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd -P)
DART=$(realpath -- "$DART")
SDK=$(dirname -- "$(dirname -- "$DART")")
case $(uname -m) in
  x86_64|amd64) ARCH=x64; DEB_ARCH=amd64;;
  aarch64|arm64) ARCH=arm64; DEB_ARCH=arm64;;
  *) printf '当前脚本只打包Linux x64/arm64。\n' >&2; exit 1;;
esac
export PUB_CACHE="$ROOT/.local/pub-cache"
export TMPDIR="$ROOT/.local/temp"
export HOME="$ROOT/.local/dart-user-linux"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"
export DART_SUPPRESS_ANALYTICS=true
mkdir -p -- "$PUB_CACHE" "$TMPDIR" "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$ROOT/.local/package-build"
BUILD=$(mktemp -d "$ROOT/.local/package-build/linux.XXXXXXXX")
NAME="zaizuo-cli-$VERSION-linux-$ARCH"
STAGE="$BUILD/$NAME"
ARCHIVE="$OUT/$NAME.tar.gz"
PACKAGE="$OUT/zaizuo-cli_${VERSION}_${DEB_ARCH}.deb"
for target in "$ARCHIVE" "$ARCHIVE.sha256"; do
  [[ ! -e $target ]] || { printf '拒绝覆盖已有产物：%s\n' "$target" >&2; exit 1; }
done
if [[ $DEB != no ]]; then
  for target in "$PACKAGE" "$PACKAGE.sha256"; do
    [[ ! -e $target ]] || { printf '拒绝覆盖已有产物：%s\n' "$target" >&2; exit 1; }
  done
fi
mkdir -p -- "$STAGE/bin" "$STAGE/licenses"
DART_VERSION=$("$DART" --version 2>&1)
[[ $DART_VERSION == *linux* ]] || { printf '需要Linux Dart SDK。\n' >&2; exit 1; }
(
  cd -- "$ROOT/packages/runtime"
  if ((PUB_GET)); then "$DART" pub get --enforce-lockfile; fi
  [[ -f .dart_tool/package_config.json ]] || { printf '缺少package_config。\n' >&2; exit 1; }
  "$DART" compile exe bin/zaizuo.dart -o "$STAGE/bin/zaizuo"
)
chmod 0755 -- "$STAGE/bin/zaizuo"
"$DART" "$ROOT/tools/package/collect_licenses.dart" "$ROOT/packages/runtime/.dart_tool/package_config.json" "$ROOT/packages/runtime/pubspec.lock" "$STAGE/licenses" "$ROOT"
cp -- "$ROOT/LICENSE" "$ROOT/NOTICE" "$STAGE/"
cp -- "$SDK/LICENSE" "$STAGE/licenses/Dart-SDK-LICENSE.txt"
for notice in THIRD_PARTY_NOTICES third_party/NOTICES NOTICES; do
  if [[ -f "$SDK/$notice" ]]; then cp -- "$SDK/$notice" "$STAGE/licenses/Dart-${notice//\//-}"; fi
done
cp -- "$ROOT/tools/package/runtime.env.example" "$STAGE/runtime.env.example"
cp -- "$ROOT/tools/package/PORTABLE-README.md" "$STAGE/README.md"
cat > "$STAGE/zaizuo" <<'LAUNCHER'
#!/bin/sh
set -eu
# 不source环境模板/用户配置，不保存secret；参数原样转发。
BASE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
if [ -n "${ZAIZUO_GIT_BIN_DIR:-}" ]; then PATH="$ZAIZUO_GIT_BIN_DIR:$PATH"; fi
if [ -n "${ZAIZUO_CWEBP_BIN_DIR:-}" ]; then PATH="$ZAIZUO_CWEBP_BIN_DIR:$PATH"; fi
export PATH
exec "$BASE/bin/zaizuo" "$@"
LAUNCHER
chmod 0755 -- "$STAGE/zaizuo"
cat > "$STAGE/SOURCE.md" <<SOURCE
# 对应源码 / Corresponding Source

- Project license: AGPL-3.0-only; see LICENSE and NOTICE.
- Repository: $SOURCE_REPOSITORY
- Source tag: $SOURCE_REF
- Source URL: $SOURCE_URL
- Source download: $SOURCE_ARCHIVE
- Build instructions: $SOURCE_URL/docs/构建与安装.md
- Packaging scripts and dependency lockfiles: $SOURCE_URL/tools/package

This package was compiled from source by build-linux.sh, not repackaged from an older binary. Before distributing it, verify that the tag contains the actual corresponding source and that the source download remains available at no additional charge. Third-party notices in licenses/ retain their own terms; the project license does not replace them. See AGPL sections 6 and 13 for applicable distribution and modified network-version obligations.
SOURCE
printf '{"project":"zaizuo","version":"%s","platform":"linux-%s","mode":"exe","build_method":"native-compile","repackaged":false,"smoke_tested":%s,"smoke_scope":"help-only","git_bundled":false,"cwebp_bundled":false,"project_license":"AGPL-3.0-only","source_repository":"%s","source_ref":"%s","source_url":"%s","source_archive":"%s"}\n' "$VERSION" "$ARCH" "$([[ $SMOKE == 1 ]] && echo true || echo false)" "$SOURCE_REPOSITORY" "$SOURCE_REF" "$SOURCE_URL" "$SOURCE_ARCHIVE" > "$STAGE/BUILD.json"
printf '%s\n' "$DART_VERSION" > "$STAGE/SDK-VERSION.txt"
if ((SMOKE)); then "$STAGE/zaizuo" --help; fi
(
  cd -- "$STAGE"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
tar --owner=0 --group=0 --numeric-owner -C "$BUILD" -czf "$ARCHIVE" "$NAME"
(
  cd -- "$OUT"
  sha256sum "$(basename -- "$ARCHIVE")" > "$(basename -- "$ARCHIVE").sha256"
)
if [[ $DEB != no ]]; then
  if ! command -v dpkg-deb >/dev/null 2>&1; then
    if [[ $DEB == yes ]]; then printf '请求.deb但缺少dpkg-deb（不自动sudo安装）。portable已保留。\n' >&2; exit 1; fi
    printf '未安装dpkg-deb，仅生成portable tar.gz。\n'
  else
    PACKAGE="$OUT/zaizuo-cli_${VERSION}_${DEB_ARCH}.deb"
    [[ ! -e $PACKAGE ]] || { printf '拒绝覆盖已有deb：%s\n' "$PACKAGE" >&2; exit 1; }
    DEB_STAGE="$BUILD/deb-root"
    mkdir -p -- "$DEB_STAGE/DEBIAN" "$DEB_STAGE/usr/lib/zaizuo" "$DEB_STAGE/usr/bin" "$DEB_STAGE/usr/share/doc/zaizuo-cli/licenses" "$DEB_STAGE/usr/share/zaizuo-cli"
    cp -- "$STAGE/bin/zaizuo" "$DEB_STAGE/usr/lib/zaizuo/zaizuo"
    cp -R -- "$STAGE/licenses/." "$DEB_STAGE/usr/share/doc/zaizuo-cli/licenses/"
    cp -- "$STAGE/README.md" "$STAGE/LICENSE" "$STAGE/NOTICE" "$STAGE/SOURCE.md" "$STAGE/BUILD.json" "$STAGE/SDK-VERSION.txt" "$DEB_STAGE/usr/share/doc/zaizuo-cli/"
    cp -- "$STAGE/LICENSE" "$DEB_STAGE/usr/share/doc/zaizuo-cli/copyright"
    cp -- "$STAGE/runtime.env.example" "$DEB_STAGE/usr/share/zaizuo-cli/runtime.env.example"
    cat > "$DEB_STAGE/usr/bin/zaizuo" <<'DEB_LAUNCHER'
#!/bin/sh
set -eu
if [ -n "${ZAIZUO_GIT_BIN_DIR:-}" ]; then PATH="$ZAIZUO_GIT_BIN_DIR:$PATH"; fi
if [ -n "${ZAIZUO_CWEBP_BIN_DIR:-}" ]; then PATH="$ZAIZUO_CWEBP_BIN_DIR:$PATH"; fi
export PATH
# 支持无root dpkg-deb -x到用户目录；默认安装时BASE=/usr。
BASE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
exec "$BASE/lib/zaizuo/zaizuo" "$@"
DEB_LAUNCHER
    chmod 0755 -- "$DEB_STAGE/usr/bin/zaizuo" "$DEB_STAGE/usr/lib/zaizuo/zaizuo"
    cat > "$DEB_STAGE/DEBIAN/control" <<CONTROL
Package: zaizuo-cli
Version: $VERSION
Section: net
Priority: optional
Architecture: $DEB_ARCH
Maintainer: Zaizuo contributors <noreply@invalid.example>
Homepage: $SOURCE_REPOSITORY
Depends: libc6, libgcc-s1, libstdc++6, git
Description: Zaizuo non-UI CLI prototype for testing
 Portable native CLI, no system service or public listener is installed.
 Original project code: AGPL-3.0-only; third-party terms are retained.
 Corresponding source and notices are under /usr/share/doc/zaizuo-cli/.
CONTROL
    chmod 0755 -- "$DEB_STAGE/DEBIAN"
    chmod 0644 -- "$DEB_STAGE/DEBIAN/control"
    dpkg-deb --root-owner-group -Zxz --build "$DEB_STAGE" "$PACKAGE"
    (
      cd -- "$OUT"
      sha256sum "$(basename -- "$PACKAGE")" > "$(basename -- "$PACKAGE").sha256"
    )
    printf '已创建DEB：%s\n' "$PACKAGE"
  fi
fi
printf '已创建portable：%s\n构建中间文件保留：%s\n' "$ARCHIVE" "$BUILD"
