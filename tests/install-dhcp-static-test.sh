#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
INSTALLER="$ROOT/install-dhcp.sh"

bash -n "$INSTALLER"
bash -n "$ROOT/install.sh"
bash -n "$ROOT/pve-iptv-dhcp-create.sh"
bash -n "$ROOT/build-release.sh"

grep -q -- '--network-only' "$INSTALLER"
grep -q 'iface %s inet manual' "$INSTALLER"
! grep -q 'iface %s inet dhcp' "$INSTALLER"
grep -q 'ExecStart=/sbin/dhclient -4 -d -v' "$INSTALLER"
grep -q 'iptv-dhcp.service' "$INSTALLER"
grep -q 'iptv-network-watchdog.timer' "$INSTALLER"
grep -q 'systemctl --no-block restart iptv-spider' "$INSTALLER"
grep -q 'Before=iptv-spider.service' "$INSTALLER"
grep -q 'Wants=iptv-dhcp.service' "$INSTALLER"
grep -q 'After=iptv-dhcp.service' "$INSTALLER"
grep -q 'ExecStartPre=-/sbin/ip -4 addr flush dev' "$INSTALLER"
grep -q 'ExecStopPost=-/sbin/ip -4 addr flush dev' "$INSTALLER"
grep -q 'REPO_TAG=${REPO_TAG:-v0.3.11}' "$INSTALLER"
grep -q 'REPO_TAG=v0.3.11' "$ROOT/install-dhcp.conf.example"
grep -q 'REPO_TAG=v0.3.11' "$ROOT/pve-iptv-dhcp-create.sh"
grep -q 'v0.3.11' "$ROOT/README.md"
grep -q 'v0.3.11' "$ROOT/docs/routeros-iptv-guide-jeffz.md"

test "$(cat "$ROOT/app/VERSION")" = '1.3.0'
test "$(sed -n 's/^VERSION=${IPTV_SPIDER_PVE_VERSION:-\(v[0-9.]*\)}$/\1/p' "$ROOT/install.sh")" = 'v0.3.11'

watchdog=$(mktemp)
trap 'rm -f "$watchdog"' EXIT
awk '
  /cat > \/usr\/local\/sbin\/iptv-network-watchdog <<.WATCHDOG./ {capture=1; next}
  capture && /^WATCHDOG$/ {exit}
  capture {print}
' "$INSTALLER" > "$watchdog"
test -s "$watchdog"
bash -n "$watchdog"
grep -q 'pgrep -f' "$watchdog"
grep -q 'iptv-dhcp.service' "$watchdog"
grep -q '30\.\*' "$watchdog"
grep -q 'no IPv4 on' "$watchdog"
grep -q 'MIN_INTERVAL=300' "$watchdog"
grep -q 'cooldown' "$watchdog"

echo 'install-dhcp static checks passed'
