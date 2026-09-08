#!/usr/bin/env bash
# iptv-spider-pve 一键安装引导（PVE 侧）
#
# 在 Proxmox VE Shell 以 root 运行：
#   bash <(curl -fsSL https://raw.githubusercontent.com/driftbottle61/iptv-spider-pve/v0.2.4/install.sh)
#     （无参数=交互向导：扫描空闲 CT/IP 建议值、机顶盒抓包/手工、冲突重输）
#   参数化方式：
#   bash <(curl -fsSL https://raw.githubusercontent.com/driftbottle61/iptv-spider-pve/v0.2.4/install.sh) \
#     --answers /root/install-dhcp.conf --vmid 118 --hostname iptv-spider \
#     --mgmt-ip 192.168.100.93 --mgmt-gw 192.168.100.1 \
#     --ssh-pubkey /tmp/id_ed25519.pub
#
# 本引导只负责把同版本发行包拿到本机，其余参数原样透传给
# pve-iptv-dhcp-create.sh（完整参数表见 README.md）。
set -euo pipefail

VERSION=${IPTV_SPIDER_PVE_VERSION:-v0.2.4}
REPO=driftbottle61/iptv-spider-pve

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  echo
  echo '其余参数请参考 pve-iptv-dhcp-create.sh 的 --help：'
  echo '  无参数运行即进入交互向导（扫描空闲 CT/IP、冲突重输、机顶盒抓包）。'
  echo '  参数化：--answers <file> / --vmid / --hostname / --mgmt-ip / --mgmt-gw /'
  echo '          --eth1-mac / --ssh-pubkey / --routeros-key / ...（见 README.md）'
  exit 0
}
case "${1:-}" in
  -h|--help|help) usage ;;
esac

[ "$(id -u)" -eq 0 ] || { echo '请在 PVE Shell 以 root 运行。' >&2; exit 1; }
command -v pct >/dev/null 2>&1 || { echo '未检测到 pct，此脚本必须运行在 Proxmox VE 主机。' >&2; exit 1; }

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$SELF_DIR/pve-iptv-dhcp-create.sh" ] && [ -f "$SELF_DIR/install-dhcp.sh" ]; then
  echo "使用本地发行文件：$SELF_DIR"
  exec bash "$SELF_DIR/pve-iptv-dhcp-create.sh" "$@"
fi

command -v curl >/dev/null 2>&1 || { echo '缺少 curl。' >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo '缺少 tar。' >&2; exit 1; }

tmp=$(mktemp -d /tmp/iptv-spider-pve.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
archive="${tmp}/${VERSION}.tar.gz"
url="https://github.com/${REPO}/archive/refs/tags/${VERSION}.tar.gz"
echo "下载 iptv-spider-pve ${VERSION} ..."
curl -fL --retry 3 --retry-delay 2 -o "$archive" "$url"
tar -xzf "$archive" -C "$tmp"
root_dir="$tmp/iptv-spider-pve-${VERSION#v}"
[ -f "$root_dir/pve-iptv-dhcp-create.sh" ] || { echo '发行包结构不完整。' >&2; exit 1; }
exec bash "$root_dir/pve-iptv-dhcp-create.sh" "$@"
