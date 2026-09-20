#!/usr/bin/env bash
# update.sh 的离线测试：用假 curl/systemctl 跑通「检测 → 校验 → 安装 → 回滚」。
# 不需要网络，也不会碰真实 /opt 或 /etc；所有路径都指向临时目录。
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d /tmp/iptv-update-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

APP_VERSION=${1:-1.0.0}
NEW_VERSION=${2:-2.0.0}

fail() { echo "FAIL: $*" >&2; exit 1; }

# ---- 假 curl ----
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
out=''
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    -o) out=${args[$((i+1))]}; i=$((i+2)); continue ;;
    -H|--max-time|--retry|--retry-delay) i=$((i+2)); continue ;;
  esac
  i=$((i+1))
done
url=${args[${#args[@]}-1]}
case "$url" in
  *api.github.com*) src=$FAKE_API_JSON ;;
  *.sha256) src=$FAKE_ARCHIVE.sha256 ;;
  *.tar.gz) src=$FAKE_ARCHIVE ;;
  *) echo "假 curl 不认识：$url" >&2; exit 22 ;;
esac
# 用 cp/cat 而非 $(cat …)：应用包是二进制，命令替换会吃掉 NUL 字节
if [ -n "$out" ]; then cp -f "$src" "$out"; else cat "$src"; fi
EOF

# ---- 假 systemctl ----
cat > "$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE_SYSTEMCTL_LOG"
for arg in "$@"; do
  [ "$arg" = "${FAKE_SYSTEMCTL_FAIL:-__none__}" ] && exit 1
done
exit 0
EOF
chmod +x "$TMP/bin/curl" "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"

# ---- 造发行包（顶层 app/） ----
make_package() {
  local ver=$1 out=$2 work
  work=$(mktemp -d "$TMP/pkg.XXXXXX")
  mkdir -p "$work/app/bin" "$work/app/systemd"
  printf '%s\n' "$ver" > "$work/app/VERSION"
  printf '#!/bin/sh\necho iptv-spider %s\n' "$ver" > "$work/app/bin/iptv-spider-linux-amd64"
  chmod 0755 "$work/app/bin/iptv-spider-linux-amd64"
  printf '[Service]\nExecStart=__INSTALL_DIR__/iptv-spider\n' > "$work/app/systemd/iptv-spider.service"
  cp "$ROOT/update.sh" "$ROOT/status.sh" "$ROOT/manage.sh" "$ROOT/uninstall.sh" "$work/app/"
  cp "$ROOT/update.conf.example" "$work/app/"
  cp "$ROOT/systemd/iptv-spider-update.service" "$ROOT/systemd/iptv-spider-update.timer" "$work/app/systemd/"
  tar -C "$work" -czf "$out" app
  rm -rf "$work"
  (cd "$(dirname "$out")" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256")
}

make_package "$NEW_VERSION" "$TMP/iptv-spider-app-${NEW_VERSION}-linux-amd64.tar.gz"
export FAKE_ARCHIVE="$TMP/iptv-spider-app-${NEW_VERSION}-linux-amd64.tar.gz"

write_api_json() {
  local versions=$1 out=$2 ver
  {
    printf '[\n  {"tag_name": "v9.9.9", "assets": [\n'
    local first=1
    for ver in $versions; do
      [ "$first" = 1 ] || printf ',\n'
      first=0
      printf '    {"name": "iptv-spider-app-%s-linux-amd64.tar.gz", "browser_download_url": "https://github.com/driftbottle61/iptv-spider-pve/releases/download/v9.9.9/iptv-spider-app-%s-linux-amd64.tar.gz"}' "$ver" "$ver"
    done
    printf '\n  ]}\n]\n'
  } > "$out"
}
write_api_json "$APP_VERSION $NEW_VERSION" "$TMP/api.json"
export FAKE_API_JSON="$TMP/api.json"
export FAKE_SYSTEMCTL_LOG="$TMP/systemctl.log"
: > "$FAKE_SYSTEMCTL_LOG"

# ---- 假安装现场 ----
APP_DIR="$TMP/opt/sh-iptv-spider"
install -d -m 0755 "$APP_DIR" "$TMP/sbin" "$TMP/systemd" "$TMP/state"
printf '%s\n' "$APP_VERSION" > "$APP_DIR/VERSION"
printf 'mysql:\n  db-name: %s\n' "'iptv'" > "$APP_DIR/config.yaml"
printf 'KEEP-ME\n' >> "$APP_DIR/config.yaml"
install -d -m 0755 "$APP_DIR/bin" "$APP_DIR/systemd"
printf '#!/bin/sh\necho old\n' > "$APP_DIR/bin/iptv-spider-linux-amd64"
printf '[Service]\nExecStart=__INSTALL_DIR__/iptv-spider\n' > "$APP_DIR/systemd/iptv-spider.service"
cp "$ROOT/update.conf.example" "$APP_DIR/"

run_update() {
  IPTV_SPIDER_DIR="$APP_DIR" SBIN_DIR="$TMP/sbin" SYSTEMD_DIR="$TMP/systemd" \
  STATE_DIR="$TMP/state" UPDATE_CONF="$TMP/update.conf" STABLE_POLL=0 \
    bash "$ROOT/update.sh" "$@"
}

# ---- 1) --check 应报有新版本并以 10 退出 ----
set +e
out=$(run_update --check 2>&1)
rc=$?
set -e
[ "$rc" -eq 10 ] || fail "--check 退出码应为 10，实际 $rc：$out"
printf '%s' "$out" | grep -q "发现新版本：$APP_VERSION → $NEW_VERSION" || fail "--check 未报告新版本：$out"
[ "$(cat "$APP_DIR/VERSION")" = "$APP_VERSION" ] || fail '--check 不应改动安装'
echo 'ok: --check 检测新版本'

# ---- 2) 版本比较用 sort -V（1.10 视为比 1.9 新）----
write_api_json "1.9.0 1.10.0" "$TMP/api10.json"
FAKE_API_JSON="$TMP/api10.json" ; export FAKE_API_JSON
printf '%s\n' '1.9.0' > "$APP_DIR/VERSION"
set +e
out=$(run_update --check 2>&1)
rc=$?
set -e
[ "$rc" -eq 10 ] || fail '1.9.0 → 1.10.0 未识别为新版本'
printf '%s' "$out" | grep -q '1.9.0 → 1.10.0' || fail "版本比较错误：$out"
printf '%s\n' "$APP_VERSION" > "$APP_DIR/VERSION"
echo 'ok: 版本比较 1.10.0 > 1.9.0'

# ---- 3) 正常更新：保留 config.yaml、装到 sbin、写状态 ----
export FAKE_API_JSON="$TMP/api.json"
run_update > "$TMP/update.log" 2>&1 || { cat "$TMP/update.log"; fail '更新失败'; }
[ "$(cat "$APP_DIR/VERSION")" = "$NEW_VERSION" ] || fail '更新后 VERSION 不对'
grep -q 'KEEP-ME' "$APP_DIR/config.yaml" || fail 'config.yaml 未保留'
[ -x "$TMP/sbin/iptv-spider-update" ] || fail '未安装 iptv-spider-update'
[ -f "$TMP/systemd/iptv-spider-update.timer" ] || fail '未安装更新定时器'
grep -q 'restart' "$FAKE_SYSTEMCTL_LOG" || fail '更新未重启服务'
grep -q 'available_version=' "$TMP/state/update-state" || fail '未写更新状态文件'
grep -q 'result=updated' "$TMP/state/update-state" || fail '状态未记录 updated'
grep -q '^available_version=$' "$TMP/state/update-state" || fail '更新完成后不应再记录“有新版本”'
ls -d "$APP_DIR".update-backup.* >/dev/null 2>&1 || fail '未生成更新前备份'
[ -f "$TMP/update.conf" ] || fail '首次更新未生成 update.conf'
grep -q 'enable --now iptv-spider-update.timer' "$FAKE_SYSTEMCTL_LOG" || fail '首次更新未启用更新定时器'
echo 'ok: 正常更新（保留配置 + 安装文件 + 重启 + 备份 + 状态 + 启用定时器）'

# ---- 4) 已是最新：不动、以 0 退出 ----
set +e
out=$(run_update 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "已是最新时退出码应为 0，实际 $rc"
printf '%s' "$out" | grep -q '已是最新版本' || fail "已是最新时输出异常：$out"
echo 'ok: 已是最新时不动'

# ---- 5) 服务起不来 → 自动回滚 ----
make_package 3.0.0 "$TMP/iptv-spider-app-3.0.0-linux-amd64.tar.gz"
export FAKE_ARCHIVE="$TMP/iptv-spider-app-3.0.0-linux-amd64.tar.gz"
write_api_json "$NEW_VERSION 3.0.0" "$TMP/api3.json"
export FAKE_API_JSON="$TMP/api3.json"
set +e
out=$(FAKE_SYSTEMCTL_FAIL=restart run_update 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail '启动失败时应以非 0 退出'
printf '%s' "$out" | grep -q '回滚' || fail "未提示回滚：$out"
[ "$(cat "$APP_DIR/VERSION")" = "$NEW_VERSION" ] || fail '回滚后版本不是更新前的版本'
grep -q 'KEEP-ME' "$APP_DIR/config.yaml" || fail '回滚后 config.yaml 丢失'
grep -q 'result=failed' "$TMP/state/update-state" || fail '状态未记录 failed'
[ "$(grep -c 'enable --now iptv-spider-update.timer' "$FAKE_SYSTEMCTL_LOG")" = 1 ] \
  || fail '已存在 update.conf 时不应重复启用定时器'
echo 'ok: 启动失败自动回滚'

echo 'update logic tests passed'
