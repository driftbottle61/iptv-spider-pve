#!/usr/bin/env bash
# iptv-spider-update —— IPTV Spider 应用 + 网络层自动更新（CT 内）
#
# 流程：查本仓库 Release 里最新的 iptv-spider-app-<版本>-linux-amd64.tar.gz
#   → 与本机 $APP_DIR/VERSION 比较 → 下载 → SHA256 校验 → 备份现有安装
#   → 覆盖文件（保留 config.yaml / 数据库 / IPTV 网络配置）→ 重启服务
#   → 稳定检查 → 失败自动回滚。网络层则按 NETWORK_UPDATE 策略检查/应用
#   install-dhcp.sh --network-only，同样带备份、健康检查和回滚。
#
# 用法：
#   iptv-spider-update                   检测并更新（有新版本才动）
#   iptv-spider-update --check           只检测并报告（不下载、不改动）
#   iptv-spider-update --dry-run         下载并校验，打印将执行的动作，不改动安装
#   iptv-spider-update --force           版本相同也重装一次
#   iptv-spider-update --version 1.2.4   安装指定的应用版本
#   iptv-spider-update --status          显示本机版本与最近一次检测结果
#   iptv-spider-update --list            列出 Release 里所有可安装的应用版本
#   iptv-spider-update --network-check   只检查网络层是否有新版
#   iptv-spider-update --network-update  立即应用最新网络层（--network-only）
#   iptv-spider-update --auto            供 systemd 定时器调用（按 update.conf 决定是否安装）
#   iptv-spider-update --enable-timer    启用每日自动检测定时器
#   iptv-spider-update --disable-timer   关闭自动检测定时器
#
# 退出码：0=已是最新/更新成功；10=有新版本但未安装；1=失败（已安装的会自动回滚）
set -euo pipefail

APP_DIR=${IPTV_SPIDER_DIR:-/opt/sh-iptv-spider}
SBIN_DIR=${SBIN_DIR:-/usr/local/sbin}
SYSTEMD_DIR=${SYSTEMD_DIR:-/etc/systemd/system}
STATE_DIR=${STATE_DIR:-/var/lib/iptv-spider}
NETWORK_LAYER_FILE=${NETWORK_LAYER_FILE:-/etc/iptv-spider/network-layer.version}
NETWORK_ETH1_IF=${NETWORK_ETH1_IF:-eth1}
NETWORK_LOCK=${NETWORK_LOCK:-/var/lock/iptv-spider-network.lock}
NETWORK_HEALTH_RETRIES=${NETWORK_HEALTH_RETRIES:-30}
NETWORK_HEALTH_POLL=${NETWORK_HEALTH_POLL:-2}
NETWORK_ROUTES=${NETWORK_ROUTES:-"218.83.0.0/16 222.68.0.0/16 124.75.0.0/16"}
NETWORK_BACKUP_PATHS=${NETWORK_BACKUP_PATHS:-"/etc/network/interfaces
/etc/dhcp/dhclient-enter-hooks.d/00-iptv-dhcp-guard
/etc/dhcp/dhclient-exit-hooks.d/99-iptv-routes
/etc/iptv-spider/dhcp-direct.conf
/etc/systemd/system/iptv-dhcp.service
/etc/systemd/system/iptv-spider.service.d/10-iptv-dhcp.conf
/usr/local/sbin/iptv-network-watchdog
/etc/systemd/system/iptv-network-watchdog.service
/etc/systemd/system/iptv-network-watchdog.timer
/etc/iptv-spider/network-layer.version"}
SERVICE=iptv-spider.service
UPDATE_CONF=${UPDATE_CONF:-/etc/iptv-spider/update.conf}
STATE_FILE=$STATE_DIR/update-state
TIMER_UNIT=iptv-spider-update.timer
DEFAULT_REPO=driftbottle61/iptv-spider-pve
KEEP_BACKUPS=3

REPO=${REPO:-$DEFAULT_REPO}
GITHUB_TOKEN=${GITHUB_TOKEN:-}
AUTO_UPDATE=1
NETWORK_UPDATE=check

MODE=normal
FORCE=0
TARGET_VERSION=''
STAGE_DIR=''
NET_STAGE_DIR=''
NET_INSTALLER=''
NETWORK_LOCK_HELD=0
RELEASES_JSON=''
NET_INDEX=''

cleanup() {
  rm -rf "${STAGE_DIR:-}" "${NET_STAGE_DIR:-}"
  if [ "$NETWORK_LOCK_HELD" = 1 ]; then
    rm -rf "$NETWORK_LOCK"
  fi
  return 0
}
trap cleanup EXIT

log()  { printf '%s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '警告：%s\n' "$*" >&2; }
die()  { printf '错误：%s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --dry-run) MODE=dryrun; shift ;;
    --force) FORCE=1; shift ;;
    --auto) MODE=auto; shift ;;
    --status) MODE=status; shift ;;
    --list) MODE=list; shift ;;
    --network-check) MODE=network-check; shift ;;
    --network-update) MODE=network-update; shift ;;
    --version) TARGET_VERSION=${2:-}; [ -n "$TARGET_VERSION" ] || die '--version 需要版本号，例如 --version 1.2.4'; shift 2 ;;
    --enable-timer) MODE=enable-timer; shift ;;
    --disable-timer) MODE=disable-timer; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) die "未知参数：$1（-h 查看用法）" ;;
  esac
done

load_conf() {
  [ -r "$UPDATE_CONF" ] || return 0
  # shellcheck disable=SC1090
  . "$UPDATE_CONF"
}

local_version() { cat "$APP_DIR/VERSION" 2>/dev/null || printf '未知'; }

# 首次接管这台机器时补齐默认配置并启用每日自动检测。
# 只在 update.conf 不存在时执行——配置已存在说明用户做过选择（关掉定时器或
# 改成仅检测），之后不再触碰。安装路径与常规/自动运行都会调用，因此
# 「先装上了更新器、随后一直是已是最新」的机器也能自动补上定时器。
ensure_update_defaults() {
  [ -f "$UPDATE_CONF" ] && return 0
  [ -f "$APP_DIR/update.conf.example" ] || return 0
  install -d -m 0755 "$(dirname -- "$UPDATE_CONF")"
  install -m 0644 "$APP_DIR/update.conf.example" "$UPDATE_CONF"
  systemctl enable --now "$TIMER_UNIT" >/dev/null 2>&1 || true
  ok "已生成 $UPDATE_CONF 并启用每日自动检测"
}

# $1 > $2（按点分数字比较，兼容 1.10 > 1.9）
version_gt() {
  [ "$1" != "$2" ] || return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

write_state() {
  local result=$1 available=${2:-} net_available=${3:-}
  install -d -m 0755 "$STATE_DIR"
  {
    printf 'checked_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')"
    printf 'local_version=%s\n' "$(local_version)"
    printf 'network_layer_version=%s\n' "$(network_version)"
    printf 'available_version=%s\n' "$available"
    printf 'network_available_version=%s\n' "$net_available"
    printf 'result=%s\n' "$result"
  } > "$STATE_FILE.tmp"
  mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

# 一次取回 Release 列表，后续应用/网络层索引共用，避免重复吃 API 限流。
load_releases() {
  local api
  api="https://api.github.com/repos/${REPO}/releases?per_page=100"
  if [ -n "$GITHUB_TOKEN" ]; then
    RELEASES_JSON=$(curl -fsSL --max-time 30 -H "Authorization: Bearer ${GITHUB_TOKEN}" "$api") || return 1
  else
    RELEASES_JSON=$(curl -fsSL --max-time 30 "$api") || return 1
  fi
  [ -n "$RELEASES_JSON" ]
}

# 列出本仓库 Release 中所有应用包：输出版本<TAB>下载地址
parse_app_index() {
  local urls url ver
  urls=$(printf '%s' "$RELEASES_JSON" \
    | grep -o 'https://github\.com/[A-Za-z0-9._/-]*/iptv-spider-app-[0-9][0-9.]*-linux-amd64\.tar\.gz' \
    | sort -u) || true
  [ -n "$urls" ] || return 1
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    ver=$(printf '%s' "$url" | sed -n 's#.*/iptv-spider-app-\([0-9][0-9.]*\)-linux-amd64\.tar\.gz#\1#p')
    [ -n "$ver" ] || continue
    printf '%s\t%s\n' "$ver" "$url"
  done <<< "$urls"
}

# 列出本仓库 Release 中所有网络层安装包：输出版本<TAB>下载地址
parse_net_index() {
  local urls url ver
  urls=$(printf '%s' "$RELEASES_JSON" \
    | grep -o 'https://github\.com/[A-Za-z0-9._/-]*/iptv-spider-pve-v[0-9][0-9.]*\.tar\.gz' \
    | sort -u) || true
  [ -n "$urls" ] || return 1
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    ver=$(printf '%s' "$url" | sed -n 's#.*/download/\(v[0-9][0-9.]*\)/iptv-spider-pve-v[0-9][0-9.]*\.tar\.gz#\1#p')
    [ -n "$ver" ] || continue
    printf '%s\t%s\n' "$ver" "$url"
  done <<< "$urls"
}

asset_url_for() {
  local want=$1 line
  while IFS= read -r line; do
    if [ "${line%%$'\t'*}" = "$want" ]; then
      printf '%s' "${line#*$'\t'}"
      return 0
    fi
  done <<< "$INDEX"
  return 1
}

latest_version() {
  printf '%s\n' "$INDEX" | cut -f1 | sort -V | tail -n 1
}

net_asset_url_for() {
  local want=$1 line
  while IFS= read -r line; do
    if [ "${line%%$'\t'*}" = "$want" ]; then
      printf '%s' "${line#*$'\t'}"
      return 0
    fi
  done <<< "$NET_INDEX"
  return 1
}

latest_net_tag() {
  printf '%s\n' "$NET_INDEX" | cut -f1 | sort -V | tail -n 1
}

network_version() {
  [ -r "$NETWORK_LAYER_FILE" ] || return 0
  head -n 1 "$NETWORK_LAYER_FILE" | tr -d '[:space:]'
}

network_version_label() {
  local v
  v=$(network_version)
  [ -n "$v" ] && printf '%s' "$v" || printf '未知（旧版安装器）'
}

network_policy() {
  case "${NETWORK_UPDATE:-check}" in
    off|0|no|false) printf 'off' ;;
    check|1) printf 'check' ;;
    auto|yes|true) printf 'auto' ;;
    *) printf 'check' ;;
  esac
}

network_update_available() {
  local latest=$1 cur
  [ -n "$latest" ] || return 1
  cur=$(network_version)
  [ -n "$cur" ] || return 0
  version_gt "$latest" "$cur"
}

acquire_network_lock() {
  if ! mkdir "$NETWORK_LOCK" 2>/dev/null; then
    warn "另一个网络层更新正在进行（锁：$NETWORK_LOCK）"
    return 1
  fi
  NETWORK_LOCK_HELD=1
  printf '%s\n' "$$" > "$NETWORK_LOCK/pid" 2>/dev/null || true
}

stage_net_installer() {
  local tag=$1 url=$2 work archive
  work=$(mktemp -d /tmp/iptv-net-update.XXXXXX)
  NET_STAGE_DIR=$work
  archive="iptv-spider-pve-${tag}.tar.gz"
  log "正在下载网络层安装包 ${tag} ..."
  curl -fsSL --no-progress-meter --retry 3 --retry-delay 2 -o "$work/$archive" "$url" || {
    warn "下载失败：$url"
    return 1
  }
  curl -fsL --max-time 30 -o "$work/$archive.sha256" "$url.sha256" || {
    warn '网络层安装包缺少 .sha256，已中止。'
    return 1
  }
  (cd "$work" && sha256sum -c "$archive.sha256" >/dev/null) || {
    warn '网络层安装包 SHA256 校验失败，已中止。'
    return 1
  }
  ok '网络层安装包 SHA256 校验通过'
  tar -xzf "$work/$archive" -C "$work" || {
    warn '解开网络层安装包失败。'
    return 1
  }
  [ -f "$work/install-dhcp.sh" ] || {
    warn '网络层安装包结构不完整（缺 install-dhcp.sh）。'
    return 1
  }
  NET_INSTALLER="$work/install-dhcp.sh"
}

backup_network_files() {
  local bak=$1 f
  install -d -m 0700 "$bak"
  : > "$bak/.manifest"
  for f in $NETWORK_BACKUP_PATHS; do
    [ -e "$f" ] || continue
    printf '%s\n' "$f" >> "$bak/.manifest"
    install -d -m 0755 "$bak$(dirname -- "$f")"
    cp -a "$f" "$bak$f"
  done
}

restore_network_files() {
  local bak=$1 f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -e "$bak$f" ] || continue
    install -d -m 0755 "$(dirname -- "$f")"
    cp -a "$bak$f" "$f"
  done < "$bak/.manifest"
  for f in $NETWORK_BACKUP_PATHS; do
    grep -qxF "$f" "$bak/.manifest" || rm -f "$f"
  done
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl restart iptv-dhcp.service >/dev/null 2>&1 || true
  systemctl enable --now iptv-network-watchdog.timer >/dev/null 2>&1 || true
}

prune_network_backups() {
  local list
  list=$(ls -1dt "$STATE_DIR"/network-backup.* 2>/dev/null || true)
  [ -n "$list" ] || return 0
  printf '%s\n' "$list" | tail -n +4 | while IFS= read -r old; do
    [ -n "$old" ] && rm -rf "$old"
  done
}

network_healthy() {
  local i=0 net
  systemctl is-active --quiet iptv-dhcp.service || return 1
  while [ "$i" -lt "$NETWORK_HEALTH_RETRIES" ]; do
    ip -4 -o addr show dev "$NETWORK_ETH1_IF" scope global 2>/dev/null | grep -q 'inet ' && break
    i=$((i + 1))
    sleep "$NETWORK_HEALTH_POLL"
  done
  ip -4 -o addr show dev "$NETWORK_ETH1_IF" scope global 2>/dev/null | grep -q 'inet ' || return 1
  for net in $NETWORK_ROUTES; do
    ip route show "$net" 2>/dev/null | grep -q "dev $NETWORK_ETH1_IF" || return 1
  done
}

apply_network_update() {
  local tag=$1 url=$2 backup
  [ -n "$tag" ] && [ -n "$url" ] || {
    warn "Release 中没有可用的网络层 $tag 安装包。"
    return 1
  }
  acquire_network_lock || return 1
  stage_net_installer "$tag" "$url" || return 1
  install -d -m 0700 "$STATE_DIR"
  backup="$STATE_DIR/network-backup.$(date +%Y%m%d%H%M%S).$$"
  backup_network_files "$backup"
  log "正在应用网络层更新：$(network_version_label) → $tag ..."
  if ! NETWORK_LAYER_FILE="$NETWORK_LAYER_FILE" NETWORK_LAYER_VERSION="$tag" \
       SKIP_APT=1 ETH1_IF="$NETWORK_ETH1_IF" \
       bash "$NET_INSTALLER" --network-only; then
    warn '网络层安装脚本失败，正在回滚...'
    restore_network_files "$backup"
    return 1
  fi
  if [ "$(network_version)" != "$tag" ]; then
    warn "网络层版本标记未更新为 $tag，正在回滚..."
    restore_network_files "$backup"
    return 1
  fi
  if ! network_healthy; then
    warn '网络层健康检查失败（DHCP 地址或专网路由异常），正在回滚...'
    restore_network_files "$backup"
    return 1
  fi
  prune_network_backups
  ok "网络层更新完成：$tag（备份 $backup）"
}

stage_package() {
  local ver=$1 url=$2 work
  work=$(mktemp -d /tmp/iptv-update.XXXXXX)
  STAGE_DIR=$work
  archive="iptv-spider-app-${ver}-linux-amd64.tar.gz"
  log "正在下载 iptv-spider-app-${ver} ..."
  # --no-progress-meter：定时器在无人值守下运行，进度条只会把 journal 刷满
  curl -fsSL --no-progress-meter --retry 3 --retry-delay 2 -o "$work/$archive" "$url" || die "下载失败：$url"
  if curl -fsL --max-time 30 -o "$work/$archive.sha256" "$url.sha256"; then
    (cd "$work" && sha256sum -c "$archive.sha256" >/dev/null) || die 'SHA256 校验失败，已中止。'
    ok 'SHA256 校验通过'
  else
    warn 'Release 未提供 .sha256，跳过校验。'
  fi
  tar -xzf "$work/$archive" -C "$work" || die '解开应用包失败。'
  PKG_DIR="$work/app"
  [ -f "$PKG_DIR/VERSION" ] || die '应用包结构不完整（缺 VERSION）。'
  [ -x "$PKG_DIR/bin/iptv-spider-linux-amd64" ] || die '应用包结构不完整（缺 amd64 二进制）。'
  [ -f "$PKG_DIR/systemd/iptv-spider.service" ] || die '应用包结构不完整（缺 systemd 单元）。'
  installed_ver=$(cat "$PKG_DIR/VERSION")
  [ "$installed_ver" = "$ver" ] || die "包内版本（$installed_ver）与文件名版本（$ver）不一致，已中止。"
}

install_files() {
  local src=$1
  install -d -m 0755 "$APP_DIR"
  tar -C "$src" --exclude='./config.yaml' --exclude='./.git' -cf - . | tar -C "$APP_DIR" -xf -
  if [ -x "$APP_DIR/bin/iptv-spider-linux-amd64" ]; then
    install -m 0755 "$APP_DIR/bin/iptv-spider-linux-amd64" "$APP_DIR/iptv-spider"
  elif ! command -v go >/dev/null 2>&1; then
    die '应用包没有 amd64 二进制，系统也没有 Go。'
  else
    (cd "$APP_DIR" && go build -buildvcs=false -o iptv-spider .)
  fi
  install -d -m 0755 "$SBIN_DIR" "$SYSTEMD_DIR"
  [ -f "$APP_DIR/uninstall.sh" ] && install -m 0755 "$APP_DIR/uninstall.sh" "$SBIN_DIR/iptv-spider-uninstall"
  [ -f "$APP_DIR/status.sh" ] && install -m 0755 "$APP_DIR/status.sh" "$SBIN_DIR/iptv-spider-status"
  [ -f "$APP_DIR/manage.sh" ] && install -m 0755 "$APP_DIR/manage.sh" "$SBIN_DIR/iptv-spider"
  [ -f "$APP_DIR/update.sh" ] && install -m 0755 "$APP_DIR/update.sh" "$SBIN_DIR/iptv-spider-update"
  [ -f "$APP_DIR/systemd/iptv-spider-update.service" ] && install -m 0644 "$APP_DIR/systemd/iptv-spider-update.service" "$SYSTEMD_DIR/iptv-spider-update.service"
  [ -f "$APP_DIR/systemd/iptv-spider-update.timer" ] && install -m 0644 "$APP_DIR/systemd/iptv-spider-update.timer" "$SYSTEMD_DIR/iptv-spider-update.timer"
  sed "s|__INSTALL_DIR__|$APP_DIR|g" "$APP_DIR/systemd/iptv-spider.service" > "$SYSTEMD_DIR/iptv-spider.service"
  [ -f "$APP_DIR/config.yaml" ] && chmod 600 "$APP_DIR/config.yaml"
  systemctl daemon-reload
  ensure_update_defaults
}

wait_stable() {
  local attempt stable=0 poll=${STABLE_POLL:-1}
  for attempt in $(seq 1 30); do
    if systemctl is-active --quiet "$SERVICE"; then
      stable=$((stable + 1))
    else
      stable=0
    fi
    [ "$stable" -ge 5 ] && return 0
    sleep "$poll"
  done
  return 1
}

restore_backup() {
  local backup=$1
  systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  rm -rf "$APP_DIR"
  mv "$backup" "$APP_DIR"
  if [ -f "$APP_DIR/systemd/iptv-spider.service" ]; then
    sed "s|__INSTALL_DIR__|$APP_DIR|g" "$APP_DIR/systemd/iptv-spider.service" > "$SYSTEMD_DIR/iptv-spider.service"
    systemctl daemon-reload
  fi
  systemctl start "$SERVICE" >/dev/null 2>&1 || true
}

prune_backups() {
  local pattern=$1 list
  list=$(ls -1dt ${APP_DIR}${pattern}* 2>/dev/null || true)
  [ -n "$list" ] || return 0
  printf '%s\n' "$list" | tail -n +$((KEEP_BACKUPS + 1)) | while IFS= read -r old; do
    [ -n "$old" ] && rm -rf "$old"
  done
}

do_install() {
  local ver=$1 backup stamp
  stamp=$(date +%Y%m%d%H%M%S)
  backup="${APP_DIR}.update-backup.${stamp}.$$"
  while [ -e "$backup" ]; do backup="${backup}x"; done
  log "正在备份现有安装到 $backup ..."
  cp -a "$APP_DIR" "$backup"
  systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  if ! install_files "$PKG_DIR"; then
    warn '安装文件失败。'
    restore_backup "$backup"
    return 1
  fi
  if ! systemctl restart "$SERVICE" || ! wait_stable; then
    warn '新版本启动失败，正在回滚...'
    restore_backup "$backup"
    printf '已回滚到更新前版本（%s）。\n' "$(local_version)" >&2
    return 1
  fi
  prune_backups '.update-backup.'
  log "更新完成：$ver"
  log "更新前备份：$backup（确认稳定后可删除，仅保留最近 ${KEEP_BACKUPS} 份）"
  return 0
}

show_status() {
  local checked result avail net_avail next_run
  echo 'IPTV Spider 更新状态'
  echo '------------------------------------------------------------'
  echo "  本机应用版本：$(local_version)"
  echo "  网络层版本：$(network_version_label)"
  echo "  安装目录：$APP_DIR"
  echo "  更新源仓库：$REPO"
  echo "  网络层更新策略：$(network_policy)"
  if [ -r "$STATE_FILE" ]; then
    # 逐行取键值：状态文件里的时间戳带空格，. 进 shell 会被当成命令执行
    checked=$(sed -n 's/^checked_at=//p' "$STATE_FILE" | head -n 1)
    result=$(sed -n 's/^result=//p' "$STATE_FILE" | head -n 1)
    avail=$(sed -n 's/^available_version=//p' "$STATE_FILE" | head -n 1)
    net_avail=$(sed -n 's/^network_available_version=//p' "$STATE_FILE" | head -n 1)
    echo "  最近检测时间：${checked:-未知}"
    echo "  最近检测结果：${result:-未知}"
    [ -n "$avail" ] && echo "  最近发现版本：$avail"
    [ -n "$net_avail" ] && echo "  最近发现网络层：$net_avail"
  else
    echo '  最近检测时间：尚未检测过'
  fi
  if systemctl is-enabled --quiet "$TIMER_UNIT" 2>/dev/null; then
    next_run=$(systemctl list-timers "$TIMER_UNIT" --no-pager 2>/dev/null \
      | awk 'NR==2 && $0 !~ /timers listed/ {print $1" "$2" "$3}')
    echo "  自动检测定时器：已启用${next_run:+（下次 $next_run）}"
  else
    echo '  自动检测定时器：未启用'
  fi
  echo '------------------------------------------------------------'
}

enable_timer()   { systemctl enable --now "$TIMER_UNIT" >/dev/null 2>&1 || die "启用 $TIMER_UNIT 失败（单元是否已安装？）"; ok "已启用 $TIMER_UNIT"; }
disable_timer()  { systemctl disable --now "$TIMER_UNIT" >/dev/null 2>&1 || true; ok "已关闭 $TIMER_UNIT"; }

[ "${EUID}" -eq 0 ] || die '请使用 root 用户运行（sudo iptv-spider-update）。'

load_conf

case "$MODE" in
  status) show_status; exit 0 ;;
  enable-timer) enable_timer; exit 0 ;;
  disable-timer) disable_timer; exit 0 ;;
esac

[ -d "$APP_DIR" ] || die "未找到安装目录：$APP_DIR"
case "$MODE" in normal|auto) ensure_update_defaults ;; esac

if ! load_releases; then
  warn "无法从 GitHub 获取版本列表（网络或 API 限流；仓库 $REPO）。本次未做任何改动。"
  [ "$MODE" = auto ] && exit 0
  exit 1
fi

INDEX=$(parse_app_index || true)
NET_INDEX=$(parse_net_index || true)
NET_LATEST=$(latest_net_tag || true)
NET_URL=''
if [ -n "$NET_LATEST" ]; then
  NET_URL=$(net_asset_url_for "$NET_LATEST" || true)
fi
NET_AVAIL_TAG=''
if [ -n "$NET_URL" ] && network_update_available "$NET_LATEST"; then
  NET_AVAIL_TAG=$NET_LATEST
fi

if [ "$MODE" = network-check ]; then
  if [ -z "$NET_LATEST" ] || [ -z "$NET_URL" ]; then
    warn 'Release 中没有找到网络层安装包，无法检查网络层版本。'
    write_state 'failed' ''
    exit 1
  fi
  if [ -n "$NET_AVAIL_TAG" ]; then
    write_state 'network-update-available' '' "$NET_AVAIL_TAG"
    echo "发现新网络层：$(network_version_label) → $NET_AVAIL_TAG"
    echo '执行 iptv-spider-update --network-update 即可应用。'
    exit 10
  fi
  write_state 'network-up-to-date' ''
  echo "网络层已是最新版本（$(network_version_label)）。"
  exit 0
fi

if [ "$MODE" = network-update ]; then
  if [ -z "$NET_LATEST" ] || [ -z "$NET_URL" ]; then
    warn 'Release 中没有找到网络层安装包，无法应用网络层更新。'
    write_state 'failed' ''
    exit 1
  fi
  if [ -z "$NET_AVAIL_TAG" ] && [ "$FORCE" != 1 ]; then
    write_state 'network-up-to-date' ''
    echo "网络层已是最新版本（$(network_version_label)）。"
    exit 0
  fi
  if apply_network_update "$NET_LATEST" "$NET_URL"; then
    write_state 'network-updated' ''
    exit 0
  fi
  write_state 'failed' '' "$NET_LATEST"
  exit 1
fi

[ -n "$INDEX" ] || {
  warn "Release 中没有可用的应用安装包（仓库 $REPO）。本次未做任何改动。"
  [ "$MODE" = auto ] && exit 0
  exit 1
}

if [ -n "$TARGET_VERSION" ]; then
  NEW_VERSION=$TARGET_VERSION
  ASSET_URL=$(asset_url_for "$NEW_VERSION") || die "Release 中没有应用版本 $NEW_VERSION 的安装包。"
else
  NEW_VERSION=$(latest_version)
  ASSET_URL=$(asset_url_for "$NEW_VERSION" || true)
fi
[ -n "$NEW_VERSION" ] && [ -n "$ASSET_URL" ] || die "Release 中没有应用版本 ${NEW_VERSION:-未知} 的安装包。"

CUR_VERSION=$(local_version)
# VERSION 缺失/损坏时不做版本比较，直接走安装
case "$CUR_VERSION" in
  ''|*[!0-9.]*|*..*|.*) CUR_VERSION='' ;;
esac
CUR_LABEL=${CUR_VERSION:-未知}

if [ "$MODE" = list ]; then
  echo "可用版本（本机当前：$CUR_LABEL）："
  printf '%s\n' "$INDEX" | sort -V -r | while IFS=$'\t' read -r ver _url; do
    [ -n "$ver" ] || continue
    if [ "$ver" = "$CUR_VERSION" ]; then
      printf '    %-10s←当前\n' "$ver"
    else
      printf '    %-10s\n' "$ver"
    fi
  done
  if [ -n "$NET_LATEST" ]; then
    echo
    echo "网络层（本机当前：$(network_version_label)）："
    if [ "$NET_LATEST" = "$(network_version)" ]; then
      printf '    %-10s←当前\n' "$NET_LATEST"
    else
      printf '    %-10s\n' "$NET_LATEST"
    fi
  fi
  exit 0
fi

if [ "$MODE" = check ]; then
  APP_AVAIL_TAG=''
  if version_gt "$NEW_VERSION" "$CUR_VERSION"; then
    APP_AVAIL_TAG=$NEW_VERSION
  fi
  if [ -n "$APP_AVAIL_TAG" ] || [ -n "$NET_AVAIL_TAG" ]; then
    write_state 'update-available' "$APP_AVAIL_TAG" "$NET_AVAIL_TAG"
    [ -z "$APP_AVAIL_TAG" ] || echo "发现新版本：$CUR_LABEL → $APP_AVAIL_TAG"
    [ -z "$NET_AVAIL_TAG" ] || echo "发现新网络层：$(network_version_label) → $NET_AVAIL_TAG"
    if [ -n "$APP_AVAIL_TAG" ]; then
      echo '执行 iptv-spider-update 即可更新应用；网络层按 update.conf 的策略处理。'
    else
      echo '执行 iptv-spider-update --network-update 即可应用网络层更新。'
    fi
    exit 10
  fi
  write_state 'up-to-date' ''
  echo "已是最新版本（$CUR_LABEL）。"
  exit 0
fi

APP_INSTALL_TAG=''
APP_PENDING_TAG=''
if [ -n "$TARGET_VERSION" ]; then
  APP_INSTALL_TAG=$TARGET_VERSION
elif version_gt "$NEW_VERSION" "$CUR_VERSION" || [ "$FORCE" = 1 ]; then
  APP_INSTALL_TAG=$NEW_VERSION
fi

if [ -n "$APP_INSTALL_TAG" ] && [ "$MODE" = auto ] && [ "$AUTO_UPDATE" != 1 ]; then
  APP_PENDING_TAG=$APP_INSTALL_TAG
  APP_INSTALL_TAG=''
  echo "发现新版本：$CUR_LABEL → $APP_PENDING_TAG（AUTO_UPDATE=0，未自动安装；执行 iptv-spider-update 更新）"
fi

DID_APP=0
DID_NET=0
NET_FAILED=0

if [ -n "$APP_INSTALL_TAG" ]; then
  log "准备更新：$CUR_LABEL → $APP_INSTALL_TAG"
  stage_package "$APP_INSTALL_TAG" "$ASSET_URL"
  if [ "$MODE" = dryrun ]; then
    echo '  ✓ 下载与校验完成，将覆盖以下内容（本次为 --dry-run，未做任何改动）：'
    echo "      安装目录：$APP_DIR（保留 config.yaml）"
    echo "      服务单元：/etc/systemd/system/iptv-spider.service"
    echo "      管理命令：/usr/local/sbin/iptv-spider{,-status,-update,-uninstall}"
    rm -rf "$STAGE_DIR"
  else
    if ! do_install "$APP_INSTALL_TAG"; then
      write_state 'failed' "$APP_INSTALL_TAG" "$NET_AVAIL_TAG"
      exit 1
    fi
    DID_APP=1
    rm -rf "$STAGE_DIR"
  fi
elif [ "$MODE" != dryrun ]; then
  echo "已是最新版本（$CUR_LABEL）。"
fi

NET_PENDING_TAG=''
if [ -n "$NET_AVAIL_TAG" ]; then
  NET_PENDING_TAG=$NET_AVAIL_TAG
  policy=$(network_policy)
  if [ "$policy" = off ]; then
    echo "发现新网络层：$(network_version_label) → $NET_AVAIL_TAG（NETWORK_UPDATE=off，未应用）"
  elif [ "$MODE" = dryrun ]; then
    echo "网络层可更新：$(network_version_label) → $NET_AVAIL_TAG（--dry-run，未应用）"
  elif [ "$MODE" = auto ] && [ "$policy" != auto ]; then
    echo "发现新网络层：$(network_version_label) → $NET_AVAIL_TAG（策略为 check，未自动应用；执行 iptv-spider-update --network-update）"
  elif [ "$MODE" != auto ] && [ "$policy" = check ] && [ ! -t 0 ]; then
    echo "发现新网络层：$(network_version_label) → $NET_AVAIL_TAG（非交互运行，未应用；执行 iptv-spider-update --network-update）"
  else
    apply=1
    if [ "$MODE" != auto ] && [ "$policy" = check ]; then
      apply=0
      read -r -p "发现新网络层 $(network_version_label) → $NET_AVAIL_TAG，是否应用？[y/N]：" answer
      [[ "$answer" =~ ^[Yy]$ ]] && apply=1
    fi
    if [ "$apply" = 1 ]; then
      if apply_network_update "$NET_AVAIL_TAG" "$NET_URL"; then
        DID_NET=1
        NET_PENDING_TAG=''
      else
        NET_FAILED=1
      fi
    else
      echo "已跳过来自网络层的更新：$(network_version_label) → $NET_AVAIL_TAG"
    fi
  fi
fi

if [ "$MODE" = dryrun ]; then
  echo '--dry-run 完成：以上动作均未执行。'
  exit 0
fi

if [ "$NET_FAILED" = 1 ]; then
  result=failed
elif [ "$DID_APP" = 1 ] || [ "$DID_NET" = 1 ]; then
  result=updated
elif [ -n "$APP_PENDING_TAG" ] || [ -n "$NET_PENDING_TAG" ]; then
  result=update-available
else
  result=up-to-date
fi
write_state "$result" "$APP_PENDING_TAG" "$NET_PENDING_TAG"

[ "$DID_APP" = 1 ] && /usr/local/sbin/iptv-spider-status --skip-replay || true

if [ "$NET_FAILED" = 1 ]; then
  warn '网络层更新失败，应用层更新（如有）未回滚。'
  [ "$MODE" = auto ] && exit 0
  exit 1
fi
exit 0
