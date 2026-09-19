#!/usr/bin/env bash
# 从 app/ 源码构建二进制并打包应用发行包（维护者用，在仓库根运行）。
#
#   ./build-app.sh              构建 app/bin/ 并打包 iptv-spider-app-<ver>-linux-amd64.tar.gz(+.sha256)
#   ./build-app.sh --no-build   跳过编译，只用现有 app/bin/ 打包（用于复用已验证的二进制）
#   ./build-app.sh --out <dir>  产物输出目录（默认 ./dist）
#
# 产物顶层目录为 app/，与 install-dhcp.sh / pve-iptv-prep-oneclick.sh 期望一致。
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP="$ROOT/app"
OUT="$ROOT/dist"
DO_BUILD=1

while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) DO_BUILD=0; shift ;;
    --out) OUT=$2; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done

VERSION=$(cat "$APP/VERSION")
ARCHIVE="iptv-spider-app-${VERSION}-linux-amd64.tar.gz"

if [ "$DO_BUILD" = 1 ]; then
  command -v go >/dev/null 2>&1 || { echo '未找到 go，无法构建（可用 --no-build 复用现有 app/bin/）。' >&2; exit 1; }
  install -d -m 0755 "$APP/bin"
  echo "构建 app/bin/iptv-spider-linux-amd64 ..."
  (cd "$APP" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -buildvcs=false -trimpath -o bin/iptv-spider-linux-amd64 .)
  echo "构建 app/bin/stb-probe-linux-amd64 ..."
  (cd "$APP" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -buildvcs=false -trimpath -o bin/stb-probe-linux-amd64 ./cmd/stb-probe)
fi

for f in bin/iptv-spider-linux-amd64 bin/stb-probe-linux-amd64 systemd/iptv-spider.service; do
  [ -f "$APP/$f" ] || { echo "应用包不完整：缺 app/$f" >&2; exit 1; }
done

install -d -m 0755 "$OUT"
echo "打包 $ARCHIVE ..."
# 固定 mtime/属主/排序 + gzip -n，保证同样内容产出同样的字节（便于校验与复现）
tar -C "$ROOT" --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
  --exclude='app/.git' --exclude='app/config.yaml' --exclude='*.tar.gz' \
  -cf - app | gzip -9n > "$OUT/$ARCHIVE"
(cd "$OUT" && sha256sum "$ARCHIVE" > "$ARCHIVE.sha256")

echo
echo "产物："
ls -l "$OUT/$ARCHIVE" "$OUT/$ARCHIVE.sha256"
echo "二进制 sha256："
sha256sum "$APP/bin/iptv-spider-linux-amd64" "$APP/bin/stb-probe-linux-amd64"
cat "$OUT/$ARCHIVE.sha256"
