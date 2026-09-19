#!/usr/bin/env bash
set -euo pipefail

VERSION="1.2.1"
REPO_TAG="v0.3.0"
REPOSITORY="driftbottle61/iptv-spider-pve"
ARCHIVE="iptv-spider-app-${VERSION}-linux-amd64.tar.gz"
BASE_URL="https://github.com/${REPOSITORY}/releases/download/${REPO_TAG}"

[[ $(id -u) -eq 0 ]] || { echo '请在 PVE Shell 以 root 运行。'; exit 1; }
command -v pct >/dev/null || { echo '未检测到 pct，此脚本必须运行在 Proxmox VE 主机。'; exit 1; }
command -v curl >/dev/null || { echo '缺少 curl，请先执行：apt-get update && apt-get install -y curl'; exit 1; }
command -v tar >/dev/null || { echo '缺少 tar。'; exit 1; }

work_dir=$(mktemp -d /tmp/iptv-prep.XXXXXX)
trap 'rm -rf "$work_dir"' EXIT
archive_path="$work_dir/$ARCHIVE"
echo "正在下载 IPTV Spider ${VERSION} 前置组件..."
curl -fL --retry 3 --retry-delay 2 -o "$archive_path" "$BASE_URL/$ARCHIVE"
if curl -fL --retry 3 --retry-delay 2 -o "$work_dir/$ARCHIVE.sha256" "$BASE_URL/$ARCHIVE.sha256"; then
  (cd "$work_dir" && sha256sum -c "$ARCHIVE.sha256")
else
  echo '警告：Release 未提供 SHA256 文件，跳过校验。' >&2
fi

tar -xzf "$archive_path" -C "$work_dir"
root="$work_dir/app"
[[ -x "$root/pve-iptv-prep.sh" ]] || { echo '安装包缺少 pve-iptv-prep.sh。'; exit 1; }
[[ -x "$root/bin/stb-probe-linux-amd64" ]] || { echo '安装包缺少 stb-probe。'; exit 1; }
export IPTV_STB_PROBE="$root/bin/stb-probe-linux-amd64"
exec "$root/pve-iptv-prep.sh" "$@"
