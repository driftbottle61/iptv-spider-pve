#!/usr/bin/env bash
# iptv-spider-update —— IPTV Spider 应用自动更新（CT 内）
#
# 流程：查本仓库 Release 里最新的 iptv-spider-app-<版本>-linux-amd64.tar.gz
#   → 与本机 $APP_DIR/VERSION 比较 → 下载 → SHA256 校验 → 备份现有安装
#   → 覆盖文件（保留 config.yaml / 数据库 / IPTV 网络配置）→ 重启服务
#   → 稳定检查 → 失败自动回滚。
#
# 用法：
#   iptv-spider-update                   检测并更新（有新版本才动）
#   iptv-spider-update --check           只检测并报告（不下载、不改动）
#   iptv-spider-update --dry-run         下载并校验，打印将执行的动作，不改动安装
#   iptv-spider-update --force           版本相同也重装一次
#   iptv-spider-update --version 1.2.4   安装指定的应用版本
#   iptv-spider-update --status          显示本机版本与最近一次检测结果
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
SERVICE=iptv-spider.service
UPDATE_CONF=${UPDATE_CONF:-/etc/iptv-spider/update.conf}
STATE_FILE=$STATE_DIR/update-state
TIMER_UNIT=iptv-spider-update.timer
DEFAULT_REPO=driftbottle61/iptv-spider-pve
KEEP_BACKUPS=3

REPO=${REPO:-$DEFAULT_REPO}
GITHUB_TOKEN=${GITHUB_TOKEN:-}
AUTO_UPDATE=1

MODE=normal
TARGET_VERSION=''

log()  { printf '%s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '警告：%s\n' "$*" >&2; }
die()  { printf '错误：%s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --dry-run) MODE=dryrun; shift ;;
    --force) MODE=force; shift ;;
    --auto) MODE=auto; shift ;;
    --status) MODE=status; shift ;;
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

# $1 > $2（按点分数字比较，兼容 1.10 > 1.9）
version_gt() {
  [ "$1" != "$2" ] || return 1
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

write_state() {
  local result=$1 available=${2:-}
  install -d -m 0755 "$STATE_DIR"
  {
    printf 'checked_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')"
    printf 'local_version=%s\n' "$(local_version)"
    printf 'available_version=%s\n' "$available"
    printf 'result=%s\n' "$result"
  } > "$STATE_FILE.tmp"
  mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

# 列出本仓库 Release 中所有应用包：输出版本<TAB>下载地址
fetch_index() {
  local api json urls url ver
  api="https://api.github.com/repos/${REPO}/releases?per_page=100"
  if [ -n "$GITHUB_TOKEN" ]; then
    json=$(curl -fsSL --max-time 30 -H "Authorization: Bearer ${GITHUB_TOKEN}" "$api") || return 1
  else
    json=$(curl -fsSL --max-time 30 "$api") || return 1
  fi
  urls=$(printf '%s' "$json" \
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

stage_package() {
  local ver=$1 url=$2 work
  work=$(mktemp -d /tmp/iptv-update.XXXXXX)
  STAGE_DIR=$work
  archive="iptv-spider-app-${ver}-linux-amd64.tar.gz"
  log "正在下载 iptv-spider-app-${ver} ..."
  curl -fL --retry 3 --retry-delay 2 -o "$work/$archive" "$url" || die "下载失败：$url"
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
  echo 'IPTV Spider 更新状态'
  echo '------------------------------------------------------------'
  echo "  本机应用版本：$(local_version)"
  echo "  安装目录：$APP_DIR"
  echo "  更新源仓库：$REPO"
  if [ -r "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    echo "  最近检测时间：${checked_at:-未知}"
    echo "  最近检测结果：${result:-未知}"
    [ -n "${available_version:-}" ] && echo "  最近发现版本：${available_version}"
  else
    echo '  最近检测时间：尚未检测过'
  fi
  if systemctl is-enabled --quiet "$TIMER_UNIT" 2>/dev/null; then
    echo "  自动检测定时器：已启用（下次 $(systemctl list-timers "$TIMER_UNIT" --no-pager 2>/dev/null | awk 'NR==1{print $1" "$2" "$3}')）"
  else
    echo '  自动检测定时器：未启用'
  fi
  echo '------------------------------------------------------------'
}

enable_timer()   { systemctl enable --now "$TIMER_UNIT" >/dev/null 2>&1 || die "启用 $TIMER_UNIT 失败（单元是否已安装？）"; ok "已启用 $TIMER_UNIT"; }
disable_timer()  { systemctl disable --now "$TIMER_UNIT" >/dev/null 2>&1 || true; ok "已关闭 $TIMER_UNIT"; }

[ "${EUID}" -eq 0 ] || die '请使用 root 用户运行（sudo iptv-spider-update）。'

case "$MODE" in
  status) show_status; exit 0 ;;
  enable-timer) enable_timer; exit 0 ;;
  disable-timer) disable_timer; exit 0 ;;
esac

load_conf
[ -d "$APP_DIR" ] || die "未找到安装目录：$APP_DIR"

INDEX=$(fetch_index) || {
  warn "无法从 GitHub 获取版本列表（网络或 API 限流；仓库 $REPO）。本次未做任何改动。"
  [ "$MODE" = auto ] && exit 0
  exit 1
}

if [ -n "$TARGET_VERSION" ]; then
  NEW_VERSION=$TARGET_VERSION
  ASSET_URL=$(asset_url_for "$NEW_VERSION") || die "Release 中没有应用版本 $NEW_VERSION 的安装包。"
else
  NEW_VERSION=$(latest_version)
  ASSET_URL=$(asset_url_for "$NEW_VERSION")
fi

CUR_VERSION=$(local_version)

if [ "$MODE" = check ]; then
  if version_gt "$NEW_VERSION" "$CUR_VERSION"; then
    write_state 'update-available' "$NEW_VERSION"
    echo "发现新版本：$CUR_VERSION → $NEW_VERSION"
    echo '执行 iptv-spider-update 即可更新。'
    exit 10
  fi
  write_state 'up-to-date' ''
  echo "已是最新版本（$CUR_VERSION）。"
  exit 0
fi

if [ "$MODE" != force ] && [ -z "$TARGET_VERSION" ] && ! version_gt "$NEW_VERSION" "$CUR_VERSION"; then
  write_state 'up-to-date' ''
  echo "已是最新版本（$CUR_VERSION）。"
  exit 0
fi

if [ "$MODE" = auto ] && [ "$AUTO_UPDATE" != 1 ]; then
  write_state 'update-available' "$NEW_VERSION"
  echo "发现新版本：$CUR_VERSION → $NEW_VERSION（AUTO_UPDATE=0，未自动安装）"
  exit 10
fi

log "准备更新：$CUR_VERSION → $NEW_VERSION"
stage_package "$NEW_VERSION" "$ASSET_URL"

if [ "$MODE" = dryrun ]; then
  echo '  ✓ 下载与校验完成，将覆盖以下内容（本次为 --dry-run，未做任何改动）：'
  echo "      安装目录：$APP_DIR（保留 config.yaml）"
  echo "      服务单元：/etc/systemd/system/iptv-spider.service"
  echo "      管理命令：/usr/local/sbin/iptv-spider{,-status,-update,-uninstall}"
  rm -rf "$STAGE_DIR"
  exit 0
fi

if ! do_install "$NEW_VERSION"; then
  write_state 'failed' "$NEW_VERSION"
  exit 1
fi
rm -rf "$STAGE_DIR"
write_state 'updated' ''
/usr/local/sbin/iptv-spider-status --skip-replay || true
exit 0
