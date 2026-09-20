#!/usr/bin/env bash
# install-dhcp.sh - IPTV Spider "DHCP-direct" node bootstrap
#
# 在全新 Debian 12 CT 内以 root 运行，一次完成：
#   1. eth1 改为 DHCP（专网租约，含 PVE veth 固定 MAC 约定）
#   2. dhclient hooks：拦默认路由/DNS 改写，并按"租约网关"维护 IPTV 专网路由
#   3. 可选：预置 DUID（配合固定 MAC 可续用原租约 IP）
#   4. 安装 /opt/sh-iptv-spider 应用（本地发行目录或 GitHub Release）
#   5. 机顶盒认证参数：STB_MODE=manual 用 answers 中的 STB_*；
#      STB_MODE=capture 时经 RouterOS 抓包自动获取（交互：需重启实体机顶盒），
#      失败可降级为手工填写；专网 IP 由 eth1 DHCP 租约提供，无需抓包
#   6. 本地 MariaDB + config.yaml（stb.ip 自动写为当前租约 IP）
#   7. 服务启动 + 首次 EPG 抓取统计 + 直连路径验证
#
# 用法：
#   bash install-dhcp.sh <answers.conf>
#
# answers.conf 为 shell 格式 KEY=value（见 install-dhcp.conf.example）。
# 本脚本可从安装目录直接运行（自动使用同目录发行包），也可通过
# INSTALL_SOURCE=github 从 GitHub Release 下载同版本发行包。
# STB_MODE=capture 时建议由 pve-iptv-dhcp-create.sh 在交互终端中执行本脚本
# （RouterOS 抓包需要输入并等待重启实体机顶盒）。
set -euo pipefail

ANSWERS_FILE=${1:-/root/install-dhcp.conf}
if [ ! -r "$ANSWERS_FILE" ]; then
  echo "找不到参数文件：$ANSWERS_FILE" >&2
  exit 1
fi

# ---- defaults ----
APP_DIR=${APP_DIR:-/opt/sh-iptv-spider}
PORT=${PORT:-8888}
LAN_IP=${LAN_IP:-}
ETH1_IF=${ETH1_IF:-eth1}
MYSQL_HOST=${MYSQL_HOST:-127.0.0.1}
MYSQL_DB=${MYSQL_DB:-iptv}
MYSQL_USER=${MYSQL_USER:-iptv}
MYSQL_PASSWORD=${MYSQL_PASSWORD:-}
CATCHUP_DAYS=${CATCHUP_DAYS:-7}
UDPXY=${UDPXY:-}
SOURCE_M3U=${SOURCE_M3U:-}
RELAY_CLIENTS=${RELAY_CLIENTS:-}
STB_UID=${STB_UID:-}
STB_MAC=${STB_MAC:-}
STB_SN=${STB_SN:-}
STB_TYPE=${STB_TYPE:-B860A}
STB_AUTH_HOST=${STB_AUTH_HOST:-222.68.208.73:7001}
STB_PLANE_A_IP=${STB_PLANE_A_IP:-}
STB_PLANE_B_GATEWAY=${STB_PLANE_B_GATEWAY:-}
STB_MODE=${STB_MODE:-manual}
ROUTER_PRESET=${ROUTER_PRESET:-0}
ROUTER_HOST=${ROUTER_HOST:-192.168.100.1}
ROUTER_PORT=${ROUTER_PORT:-1314}
ROUTER_USER=${ROUTER_USER:-david_ni}
ROUTER_AUTH=${ROUTER_AUTH:-key}
ROUTER_KEY=${ROUTER_KEY:-/root/.ssh/id_ed25519_routeros}
ROUTER_PASSWORD=${ROUTER_PASSWORD:-}
ROUTER_IFACE=${ROUTER_IFACE:-ether3_lan}
CAPTURE_SECONDS=${CAPTURE_SECONDS:-120}
DHCP_DUID=${DHCP_DUID:-}
INSTALL_SOURCE=${INSTALL_SOURCE:-auto}
VERSION=${VERSION:-1.2.9}                # 应用版本：决定发行资产文件名
REPO_TAG=${REPO_TAG:-v0.3.8}             # 本仓库 Release 标签：决定资产所在路径
REPOSITORY=${REPOSITORY:-driftbottle61/iptv-spider-pve}
# 发行包临时目录（脚本级，便于 EXIT trap 清理；见 ensure_pkg 注释）
PKG_TMPDIR=''
trap 'rm -rf "${PKG_TMPDIR:-}"' EXIT
SYNC_CONF=/etc/iptv-spider/dhcp-direct.conf
IPTV_NETS='218.83.0.0/16 222.68.0.0/16 124.75.0.0/16'

# ---- load answers ----
. "$ANSWERS_FILE"

[ "$(id -u)" -eq 0 ] || { echo '请以 root 运行。' >&2; exit 1; }
required_keys='LAN_IP MYSQL_PASSWORD'
if [ "$STB_MODE" != capture ]; then
  required_keys="$required_keys STB_UID STB_MAC STB_SN"
fi
for key in $required_keys; do
  if [ -z "${!key:-}" ]; then
    echo "参数文件缺少必需字段：$key" >&2
    exit 1
  fi
done
case "$PORT" in
  ''|*[!0-9]*) echo "PORT 无效：$PORT" >&2; exit 1 ;;
esac

log()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    %s\n' "$*"; }
die()  { printf '错误：%s\n' "$*" >&2; exit 1; }
ask() {
  local p=$1 d=${2-} v
  printf '%s' "$p" >&2
  [ -n "$d" ] && printf ' [%s]' "$d" >&2
  printf '：' >&2
  IFS= read -r v || v=''
  printf '%s' "${v:-$d}"
}
ask_secret() {
  local p=$1 v
  printf '%s' "$p" >&2
  read -rs v || v=''
  printf '\n' >&2
  printf '%s' "$v"
}

yaml_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
sql_escape()  { printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/''/g"; }
valid_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local p
  IFS=. read -r -a p <<< "$1"
  for part in "${p[@]}"; do
    [ "$part" -ge 0 ] && [ "$part" -le 255 ] || return 1
  done
}

# ---------------------------------------------------------------- network ---
write_interfaces() {
  local file=/etc/network/interfaces tmp
  cp -a "$file" "$file.bak-dhcponly.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  tmp=$(mktemp /tmp/interfaces.XXXXXX)
  awk '
    $0 == "# BEGIN IPTV-SPIDER DHCP" {skip=1; next}
    $0 == "# END IPTV-SPIDER DHCP" {skip=0; next}
    !skip {print}
  ' "$file" > "$tmp"
  {
    cat "$tmp"
    printf '\n# BEGIN IPTV-SPIDER DHCP\n'
    printf 'auto %s\n' "$ETH1_IF"
    printf 'iface %s inet dhcp\n' "$ETH1_IF"
    printf '\tpre-up ip link set dev %s up\n' "$ETH1_IF"
    printf '# END IPTV-SPIDER DHCP\n'
  } > "$file"
  rm -f "$tmp"
  ok "已写入 /etc/network/interfaces：$ETH1_IF = inet dhcp（标记段 IPTV-SPIDER DHCP）"
}

write_hooks() {
  install -d -m 0755 /etc/dhcp/dhclient-enter-hooks.d /etc/dhcp/dhclient-exit-hooks.d /etc/iptv-spider
  cat > /etc/dhcp/dhclient-enter-hooks.d/00-iptv-dhcp-guard <<'HOOK'
#!/bin/sh
# IPTV 租约只用于专网：不改默认路由、不动 resolv.conf；记下租约网关供 exit hook 使用。
case "$reason" in
BOUND|RENEW|REBIND|RECOVER)
	interface="${interface:-eth1}"
	gw="${new_routers:-$new_dhcp_server_identifier}"
	[ -n "$gw" ] && printf '%s\n' "$gw" > "/run/iptv-lease-gw-$interface"
	unset new_routers new_domain_name_servers new_domain_name
	;;
esac
HOOK
  chmod 755 /etc/dhcp/dhclient-enter-hooks.d/00-iptv-dhcp-guard

  cat > /etc/dhcp/dhclient-exit-hooks.d/99-iptv-routes <<'HOOK'
#!/bin/sh
# DHCP 事件后按"租约网关 + 租约 IP"维护 IPTV 专网路由；同时把 config.yaml 的
# stb.ip 同步为当前租约 IP（变化时自动重启 iptv-spider）。注意：本文件被
# dhclient-script 以 source 方式执行，禁止 exit，只允许 return。
interface="${interface:-eth1}"
IPTV_NETS='218.83.0.0/16 222.68.0.0/16 124.75.0.0/16'
SYNC_CONF=/etc/iptv-spider/dhcp-direct.conf
case "$reason" in
BOUND|RENEW|REBIND|RECOVER)
	[ -n "${new_ip_address:-}" ] || return 0
	gw="$(cat "/run/iptv-lease-gw-$interface" 2>/dev/null)"
	[ -n "$gw" ] || return 0
	printf '%s %s\n' "$gw" "$new_ip_address" > "/run/iptv-lease-state-$interface"
	for net in $IPTV_NETS; do
		ip route replace "$net" via "$gw" dev "$interface" src "$new_ip_address" 2>/dev/null
	done
	logger -t iptv-dhcp "$reason: IPTV routes via $gw src $new_ip_address on $interface"
	[ -f "$SYNC_CONF" ] || return 0
	. "$SYNC_CONF"
	[ -n "${APP_DIR:-}" ] && [ -f "$APP_DIR/config.yaml" ] || return 0
	old_ip="$(sed -n "s/^[[:space:]]*ip:[[:space:]]*'\([^']*\)'.*/\1/p" "$APP_DIR/config.yaml" 2>/dev/null | tail -n1)"
	if [ -n "$old_ip" ] && [ "$old_ip" != "$new_ip_address" ]; then
		sed -i "s/^\([[:space:]]*ip:[[:space:]]*'\)[^']*\('\)/\1$new_ip_address\2/" "$APP_DIR/config.yaml" 2>/dev/null
		logger -t iptv-dhcp "$reason: config.yaml stb.ip $old_ip -> $new_ip_address"
		systemctl restart iptv-spider 2>/dev/null || true
	fi
	;;
EXPIRE|RELEASE|FAIL|STOP)
	[ -s "/run/iptv-lease-state-$interface" ] || return 0
	read -r gw old_ip < "/run/iptv-lease-state-$interface"
	for net in $IPTV_NETS; do
		ip route del "$net" via "$gw" dev "$interface" src "$old_ip" 2>/dev/null
	done
	rm -f "/run/iptv-lease-state-$interface" "/run/iptv-lease-gw-$interface"
	logger -t iptv-dhcp "$reason: IPTV routes removed on $interface"
	;;
esac
HOOK
  chmod 755 /etc/dhcp/dhclient-exit-hooks.d/99-iptv-routes

  cat > "$SYNC_CONF" <<EOF
APP_DIR=$(printf '%q' "$APP_DIR")
ETH1_IF=$(printf '%q' "$ETH1_IF")
EOF
  chmod 600 "$SYNC_CONF"
  ok "已写入 dhclient hooks 与 $SYNC_CONF"
}

seed_duid() {
  [ -n "$DHCP_DUID" ] || return 0
  local dir lease_file tmp
  dir=/var/lib/dhcp
  lease_file="$dir/dhclient.$ETH1_IF.leases"
  install -d -m 0755 "$dir"
  tmp=$(mktemp)
  if [ -f "$lease_file" ]; then
    grep -v '^default-duid ' "$lease_file" > "$tmp" || true
  fi
  printf 'default-duid "%s";\n' "$DHCP_DUID" > "$lease_file"
  cat "$tmp" >> "$lease_file"
  rm -f "$tmp"
  chmod 600 "$lease_file"
  ok "已预置 DUID 到 $lease_file（续用原租约）"
}

bring_up_eth1() {
  log "启动 $ETH1_IF DHCP（专网租约）"
  ip link set dev "$ETH1_IF" up 2>/dev/null || true
  rm -f "/run/iptv-lease-gw-$ETH1_IF" "/run/iptv-lease-state-$ETH1_IF"
  ifup "$ETH1_IF" >/dev/null 2>&1 || true
  LEASE_IP=''
  LEASE_GW=''
  for i in $(seq 1 45); do
    LEASE_IP=$(ip -4 -o addr show dev "$ETH1_IF" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
    if [ -n "$LEASE_IP" ] && [ -s "/run/iptv-lease-gw-$ETH1_IF" ]; then
      LEASE_GW=$(cat "/run/iptv-lease-gw-$ETH1_IF")
      break
    fi
    sleep 1
  done
  valid_ipv4 "${LEASE_IP:-}" || die "$ETH1_IF 在 45 秒内未拿到 DHCP 租约；请检查网桥/VLAN/上游 DHCP。诊断：dhclient -4 -v $ETH1_IF"
  if ! valid_ipv4 "${LEASE_GW:-}"; then
    # 重跑/已有租约时无新 BOUND 事件，从租约文件恢复网关
    LEASE_GW=$(sed -n 's/^[[:space:]]*option routers[[:space:]]*//p' "/var/lib/dhcp/dhclient.$ETH1_IF.leases" 2>/dev/null | tail -n1 | tr -d ';' | xargs)
    valid_ipv4 "${LEASE_GW:-}" || die "$ETH1_IF 已拿地址 $LEASE_IP，但未记录租约网关。"
    for net in $IPTV_NETS; do
      ip route replace "$net" via "$LEASE_GW" dev "$ETH1_IF" src "$LEASE_IP"
    done
  fi
  ok "$ETH1_IF = $LEASE_IP/16，租约网关 $LEASE_GW"
  ip route get 222.68.208.73 >/dev/null 2>&1 || true
  ip route | grep -E "(${IPTV_NETS// /|})" | sed 's/^/    路由: /' || true
}

# ---------------------------------------------------------------- app pkg ---
ensure_pkg() {
  if [ "$INSTALL_SOURCE" = "auto" ] || [ "$INSTALL_SOURCE" = "local" ]; then
    SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    if [ -d "$SCRIPT_DIR/bin" ] && [ -f "$SCRIPT_DIR/systemd/iptv-spider.service" ] && [ -x "$SCRIPT_DIR/bin/iptv-spider-linux-amd64" ]; then
      PKG_DIR=$SCRIPT_DIR
      ok "使用本地发行目录：$PKG_DIR"
      return 0
    fi
    if [ "$INSTALL_SOURCE" = "local" ]; then
      die "INSTALL_SOURCE=local 但本脚本旁没有完整发行包（缺 bin/systemd）。"
    fi
  fi
  command -v curl >/dev/null 2>&1 || die '缺少 curl。'
  # 注意：临时目录必须是脚本级变量——若声明为 local 并在函数内注册 EXIT trap，
  # 函数返回后 trap 触发时该变量已消失，set -u 下会报 "tmp: unbound variable" 并让
  # 整个安装以非 0 退出（旧写法如此，由 v0.3.0 全新安装实测发现）。清理在脚本顶部注册。
  local archive url checksum_url
  PKG_TMPDIR=$(mktemp -d /tmp/iptv-pkg.XXXXXX)
  archive="iptv-spider-app-${VERSION}-linux-amd64.tar.gz"
  url="https://github.com/${REPOSITORY}/releases/download/${REPO_TAG}/${archive}"
  ok "下载发行包 $archive"
  curl -fL --retry 3 --retry-delay 2 -o "$PKG_TMPDIR/$archive" "$url" || die "下载失败：$url"
  if curl -fsL --max-time 20 -o "$PKG_TMPDIR/$archive.sha256" "$url.sha256"; then
    (cd "$PKG_TMPDIR" && sha256sum -c "$archive.sha256" >/dev/null) || die '发行包 SHA256 校验失败。'
  fi
  tar -xzf "$PKG_TMPDIR/$archive" -C "$PKG_TMPDIR"
  PKG_DIR="$PKG_TMPDIR/app"
  [ -f "$PKG_DIR/systemd/iptv-spider.service" ] || die '发行包结构不完整。'
  ok "使用 GitHub Release ${REPO_TAG} 发行包（app ${VERSION}）"
}

install_app_files() {
  log "安装应用到 $APP_DIR"
  install -d -m 0755 "$APP_DIR"
  tar -C "$PKG_DIR" --exclude='./config.yaml' --exclude='./.git' -cf - . | tar -C "$APP_DIR" -xf -
  if [ -x "$APP_DIR/bin/iptv-spider-linux-amd64" ] && [ "$(uname -m)" = 'x86_64' ]; then
    install -m 0755 "$APP_DIR/bin/iptv-spider-linux-amd64" "$APP_DIR/iptv-spider"
  elif command -v go >/dev/null 2>&1; then
    (cd "$APP_DIR" && go build -buildvcs=false -o iptv-spider .)
  else
    die '发行包没有 amd64 二进制，系统也没有 Go。'
  fi
  install -m 0755 "$APP_DIR/uninstall.sh" /usr/local/sbin/iptv-spider-uninstall
  install -m 0755 "$APP_DIR/status.sh" /usr/local/sbin/iptv-spider-status
  install -m 0755 "$APP_DIR/manage.sh" /usr/local/sbin/iptv-spider
  install -m 0755 "$APP_DIR/update.sh" /usr/local/sbin/iptv-spider-update
  install -m 0644 "$APP_DIR/systemd/iptv-spider-update.service" /etc/systemd/system/iptv-spider-update.service
  install -m 0644 "$APP_DIR/systemd/iptv-spider-update.timer" /etc/systemd/system/iptv-spider-update.timer
  sed "s|__INSTALL_DIR__|$APP_DIR|g" "$APP_DIR/systemd/iptv-spider.service" > /etc/systemd/system/iptv-spider.service
  systemctl daemon-reload
  if [ ! -f /etc/iptv-spider/update.conf ]; then
    install -d -m 0755 /etc/iptv-spider
    install -m 0644 "$APP_DIR/update.conf.example" /etc/iptv-spider/update.conf
    systemctl enable --now iptv-spider-update.timer >/dev/null 2>&1 || true
  fi
  ok "应用文件与 systemd 单元已就位"
}

setup_mariadb() {
  log '配置 MariaDB'
  case "$MYSQL_HOST" in
    127.0.0.1|localhost)
      if ! command -v mariadbd >/dev/null 2>&1 && ! dpkg -s mariadb-server >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends mariadb-server
      fi
      systemctl enable --now mariadb >/dev/null 2>&1 || service mariadb start >/dev/null 2>&1 || true
      for i in $(seq 1 15); do
        mariadb-admin ping >/dev/null 2>&1 && break
        sleep 1
      done
      mariadb-admin ping >/dev/null 2>&1 || die 'MariaDB 未就绪，无法建库。'
      local user_sql pass_sql host
      user_sql=$(sql_escape "$MYSQL_USER")
      pass_sql=$(sql_escape "$MYSQL_PASSWORD")
      mariadb -e "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
      for host in localhost 127.0.0.1 %; do
        mariadb -e "CREATE USER IF NOT EXISTS '$user_sql'@'$host' IDENTIFIED BY '$pass_sql';"
        mariadb -e "ALTER USER '$user_sql'@'$host' IDENTIFIED BY '$pass_sql';"
        mariadb -e "GRANT ALL PRIVILEGES ON \`$MYSQL_DB\`.* TO '$user_sql'@'$host';"
      done
      mariadb -e 'FLUSH PRIVILEGES;'
      ok "数据库 $MYSQL_DB / 用户 $MYSQL_USER 已就绪"
      ;;
    *)
      command -v mariadb >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends mariadb-client
      ok "使用远端数据库 $MYSQL_HOST（跳过本机建库）"
      ;;
  esac
}

write_config_yaml() {
  log '写入 config.yaml'
  local relay_yaml='[]'
  if [ -n "$RELAY_CLIENTS" ]; then
    relay_yaml='['
    IFS=',' read -r -a relay_items <<< "$RELAY_CLIENTS"
    for item in "${relay_items[@]}"; do
      item=$(printf '%s' "$item" | xargs)
      [ -n "$item" ] && relay_yaml+="'$(yaml_escape "$item")',"
    done
    relay_yaml=${relay_yaml%,}']'
  fi
  {
    printf "system:\n  env: 'release'\n  addr: '0.0.0.0:%s'\n  db-type: 'mysql'\n  oss-type: ''\n\n" "$PORT"
    printf "stb:\n  uid: '%s'\n  mac: '%s'\n  sn: '%s'\n  ip: '%s'\n  type: '%s'\n  auth_host: '%s'\n  plane_a_ip: '%s'\n  plane_b_gateway: '%s'\n\n" \
      "$(yaml_escape "$STB_UID")" "$(yaml_escape "$STB_MAC")" "$(yaml_escape "$STB_SN")" \
      "$(yaml_escape "$LEASE_IP")" "$(yaml_escape "$STB_TYPE")" "$(yaml_escape "$STB_AUTH_HOST")" \
      "$(yaml_escape "$STB_PLANE_A_IP")" "$(yaml_escape "$STB_PLANE_B_GATEWAY")"
    printf "epg:\n  generator: 'sh-iptv-spider'\n  source: 'Shanghai Telecom IPTV'\n  xml_url: 'http://%s:%s/api/epg?daysAgo=%s'\n  fetch_cron: '0 0 8,16,23 * * *'\n\n" "$LAN_IP" "$PORT" "$CATCHUP_DAYS"
    printf "catchup:\n  source_m3u: '%s'\n  udpxy: '%s'\n  days: %s\n  relay_clients: %s\n\n" \
      "$(yaml_escape "$SOURCE_M3U")" "$(yaml_escape "$UDPXY")" "$CATCHUP_DAYS" "$relay_yaml"
    printf "mysql:\n  path: '%s'\n  config: 'parseTime=True&charset=utf8mb4'\n  db-name: '%s'\n  username: '%s'\n  password: '%s'\n  max-idle-conns: 10\n  max-open-conns: 50\n  log-mode: 'error'\n  log-zap: false\n\n" \
      "$(yaml_escape "$MYSQL_HOST")" "$(yaml_escape "$MYSQL_DB")" "$(yaml_escape "$MYSQL_USER")" "$(yaml_escape "$MYSQL_PASSWORD")"
    printf "cache:\n  type: 'memory'\n  prefix: 'iptv'\n  memory_interval: 60\n  default_timeout: 10\n\n"
    printf "redis:\n  db: 0\n  addr: '127.0.0.1:6379'\n  password: ''\n\n"
    printf "oss:\n  enable: false\n  upload_cron: ''\n  endpoint: ''\n  use-ssl: true\n  bucket: ''\n  access-key: ''\n  secret-key: ''\n\n"
    printf "zap:\n  level: 'info'\n  format: 'console'\n  prefix: '[sh-iptv-spider]'\n  director: 'log'\n  link-name: 'latest_log'\n  show-line: false\n  encode-level: 'LowercaseLevelEncoder'\n  stacktrace-key: 'stacktrace'\n  log-in-console: false\n"
  } > "$APP_DIR/config.yaml"
  chmod 600 "$APP_DIR/config.yaml"
  ok "config.yaml 已写入（专网 stb.ip=$LEASE_IP；抓包/机顶盒 uid=$STB_UID mac=$STB_MAC sn=$STB_SN type=$STB_TYPE auth_host=$STB_AUTH_HOST）"
  sed -n '/^stb:/,/^[a-zA-Z]/p' "$APP_DIR/config.yaml" | sed 's/^/    /'
}

wait_epg() {
  log '等待首次 EPG 抓取（最多 3 分钟）'
  local attempt count log_file fetch_complete
  count=0
  fetch_complete=0
  log_file="$APP_DIR/latest_log"
  for attempt in $(seq 1 36); do
    if ! systemctl is-active --quiet iptv-spider; then
      echo 'iptv-spider 服务未运行。'
      systemctl status iptv-spider --no-pager --lines=15 || true
      return 1
    fi
    count=$(MYSQL_PWD="$MYSQL_PASSWORD" mariadb --batch --skip-column-names \
      -h "$MYSQL_HOST" -u "$MYSQL_USER" "$MYSQL_DB" \
      -e 'SELECT COUNT(*) FROM epg_details;' 2>/dev/null || printf '0')
    if [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt 0 ] && [ -f "$log_file" ] && grep -q '更新节目信息列表完成' "$log_file"; then
      fetch_complete=1
      break
    fi
    sleep 5
  done
  if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -eq 0 ]; then
    echo '等待超时：暂无 EPG 数据。查看：journalctl -u iptv-spider -n 100 --no-pager'
    return 1
  fi
  ok "EPG 抓取完成（节目 ${count} 条，fetch_complete=$fetch_complete）"
  return 0
}

verify_paths() {
  log '验证 IPTV 直连路径'
  local auth_ok=0 epg_code=''
  if timeout 6 bash -c "</dev/tcp/222.68.208.73/7001" 2>/dev/null; then
    auth_ok=1
  fi
  [ "$auth_ok" -eq 1 ] && ok '认证 222.68.208.73:7001 可直连' || echo '警告：认证端口 7001 不可达（可能瞬时拥塞，稍后重试）'
  epg_code=$(timeout 10 curl -s -o /dev/null -w '%{http_code}' --interface "$LEASE_IP" -m 8 http://218.83.188.231:8084/ 2>/dev/null || true)
  [ -n "$epg_code" ] && ok "EPG 218.83.188.231:8084 直连 HTTP $epg_code" || echo '警告：EPG 探测无响应'
}

# ------------------------------------------------------- STB 抓包/手工 -----
yaml_value() {
  sed -n "s/^[[:space:]]*${1}:[[:space:]]*\"\(.*\)\"[[:space:]]*$/\1/p" "$2" | tail -n 1
}
stb_probe_path() {
  local p
  for p in "$APP_DIR/bin/stb-probe-linux-amd64" "${PKG_DIR:-}/bin/stb-probe-linux-amd64"; do
    [ -n "$p" ] && [ -x "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

collect_stb_capture() {
  local probe output capture_ok ans
  probe=$(stb_probe_path) || {
    echo '未找到 stb-probe 抓包工具（发行包缺 bin/stb-probe-linux-amd64）。可用 --pkg-dir 提供本地发行目录。' >&2
    return 1
  }
  if ! command -v ssh >/dev/null 2>&1 || ! command -v scp >/dev/null 2>&1 || ! command -v sshpass >/dev/null 2>&1; then
    echo '安装抓包所需组件（openssh-client / sshpass）...'
    apt-get install -y --no-install-recommends openssh-client sshpass
  fi
  if [ "$ROUTER_PRESET" != 1 ]; then
    ROUTER_HOST=$(ask 'RouterOS 地址' "$ROUTER_HOST")
    ROUTER_PORT=$(ask 'RouterOS SSH 端口' "$ROUTER_PORT")
    ROUTER_USER=$(ask 'RouterOS SSH 用户名' "$ROUTER_USER")
    ans=$(ask 'RouterOS 登录：1=SSH 私钥 2=用户名密码' "$([ "$ROUTER_AUTH" = password ] && echo 2 || echo 1)")
    if [ "$ans" = 2 ]; then
      ROUTER_AUTH=password
    else
      ROUTER_AUTH=key
    fi
    ROUTER_IFACE=$(ask '连接实体机顶盒的 RouterOS 物理端口' "$ROUTER_IFACE")
    CAPTURE_SECONDS=$(ask '抓包时长（秒）' "$CAPTURE_SECONDS")
  fi
  if [ "$ROUTER_AUTH" = password ]; then
    if [ -z "$ROUTER_PASSWORD" ]; then
      ROUTER_PASSWORD=$(ask_secret 'RouterOS SSH 密码')
    fi
    [ -n "$ROUTER_PASSWORD" ] || die 'RouterOS SSH 密码为空。'
    export STB_PROBE_ROUTER_PASSWORD="$ROUTER_PASSWORD"
  else
    [ -r "$ROUTER_KEY" ] || die "RouterOS SSH 私钥不可读：$ROUTER_KEY（请在容器内放置该私钥，或改用密码登录）"
  fi
  while :; do
    echo
    log '安装已就绪，现在进入机顶盒抓包阶段'
    ok "抓包将在 RouterOS 的机顶盒物理口（${ROUTER_IFACE}）上运行 ${CAPTURE_SECONDS} 秒。"
    ok '请确认实体机顶盒已接该口并通电待机；按回车后立即断电→上电重启机顶盒。'
    printf '输入 M 后回车改为手工填写；否则直接按回车开始抓包... '
    IFS= read -r ans || ans=''
    case "$ans" in
      [Mm]*) unset STB_PROBE_ROUTER_PASSWORD; return 1 ;;
    esac
    output=$(mktemp /tmp/stb-probe-result.XXXXXX)
    capture_ok=0
    echo
    echo '抓包已开始，请现在立即重启实体机顶盒（断电→上电）。'
    if [ "$ROUTER_AUTH" = password ]; then
      "$probe" -router "$ROUTER_HOST" -router-port "$ROUTER_PORT" -router-user "$ROUTER_USER" \
        -router-password-env STB_PROBE_ROUTER_PASSWORD \
        -interface "$ROUTER_IFACE" -duration "$CAPTURE_SECONDS" >"$output" 2>&1 || capture_ok=$?
    else
      "$probe" -router "$ROUTER_HOST" -router-port "$ROUTER_PORT" -router-user "$ROUTER_USER" \
        -router-key "$ROUTER_KEY" \
        -interface "$ROUTER_IFACE" -duration "$CAPTURE_SECONDS" >"$output" 2>&1 || capture_ok=$?
    fi
    unset STB_PROBE_ROUTER_PASSWORD
    echo
    echo '检测到的机顶盒数据：'
    echo '------------------------------------------------------------'
    cat "$output"
    echo '------------------------------------------------------------'
    STB_UID=$(yaml_value uid "$output")
    STB_MAC=$(yaml_value mac "$output")
    STB_SN=$(yaml_value sn "$output")
    STB_TYPE=$(yaml_value type "$output")
    STB_AUTH_HOST=$(yaml_value auth_host "$output")
    STB_PLANE_A_IP=$(yaml_value plane_a_ip "$output")
    STB_PLANE_B_GATEWAY=$(yaml_value plane_b_gateway "$output")
    rm -f "$output"
    if [ "$capture_ok" -eq 0 ] && [ -n "$STB_UID" ] && [ -n "$STB_MAC" ] && [ -n "$STB_SN" ]; then
      [ -n "$STB_AUTH_HOST" ] || STB_AUTH_HOST='222.68.208.73:7001'
      echo
      ok "抓包成功：UID=$STB_UID MAC=$STB_MAC SN=$STB_SN type=${STB_TYPE:-B860A}"
      return 0
    fi
    echo '本次抓包未取得全部必需认证字段（uid/mac/sn）。'
    printf '输入 R 重新抓包，或输入 M 改为手工填写 [R]：'
    IFS= read -r ans || ans='R'
    case "$ans" in
      [Mm]*) return 1 ;;
    esac
  done
}

collect_stb_manual() {
  echo
  echo '手工填写机顶盒认证参数（跳过抓包或抓包失败降级）。'
  STB_UID=$(ask 'IPTV 账号 UID' "$STB_UID")
  STB_MAC=$(ask '机顶盒 MAC' "$STB_MAC")
  STB_SN=$(ask '机顶盒 SN' "$STB_SN")
  STB_TYPE=$(ask '机顶盒型号' "${STB_TYPE:-B860A}")
  STB_PLANE_A_IP=$(ask 'A 面/LAN 地址（可留空）' "$STB_PLANE_A_IP")
  STB_PLANE_B_GATEWAY=$(ask 'B 面网关（可留空）' "$STB_PLANE_B_GATEWAY")
  return 0
}

# ---------------------------------------------------------------- main -----
log "IPTV Spider DHCP-direct 引导开始（answers=$ANSWERS_FILE）"

if [ -f "$APP_DIR/config.yaml" ]; then
  die "检测到已有安装 $APP_DIR/config.yaml。本脚本面向全新 CT；升级请用原 install.sh。"
fi

command -v apt-get >/dev/null 2>&1 || die '仅支持 Debian/Ubuntu（apt-get）。'
export DEBIAN_FRONTEND=noninteractive
log '安装系统依赖'
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl openssh-client mariadb-client isc-dhcp-client ifupdown iproute2

write_interfaces
write_hooks
seed_duid
bring_up_eth1
ensure_pkg
install_app_files

# STB 认证参数：capture 模式经 RouterOS 抓包自动获取（专网 IP 已由 eth1 DHCP 提供）
if [ "$STB_MODE" = capture ] && { [ -z "$STB_UID" ] || [ -z "$STB_MAC" ] || [ -z "$STB_SN" ]; }; then
  log '获取机顶盒认证参数（RouterOS 抓包）'
  collect_stb_capture || collect_stb_manual
fi
[ -n "$STB_TYPE" ] || STB_TYPE=B860A
for key in STB_UID STB_MAC STB_SN STB_TYPE MYSQL_PASSWORD; do
  [ -n "${!key:-}" ] || die "缺少必需机顶盒/数据库参数：$key（STB_MODE=$STB_MODE，请补全后重跑本脚本）"
done

setup_mariadb
write_config_yaml

log '启动 iptv-spider 服务'
systemctl enable iptv-spider >/dev/null
systemctl restart iptv-spider
for i in $(seq 1 10); do
  systemctl is-active --quiet iptv-spider && break
  sleep 1
done
systemctl is-active --quiet iptv-spider || die 'iptv-spider 启动失败。日志：journalctl -u iptv-spider -n 100 --no-pager'
ok 'iptv-spider 运行中'

wait_epg || true
verify_paths

# 播放器 M3U 链接（udpxy 有配置时带上参数；留空则用服务内置默认 192.168.100.51:4022）
m3u_tivimate="http://$LAN_IP:$PORT/tv.m3u"
m3u_iptvsharp="http://$LAN_IP:$PORT/iptvsharp.m3u"
if [ -n "$UDPXY" ]; then
  m3u_tivimate="$m3u_tivimate?udpxy=$UDPXY"
  m3u_iptvsharp="$m3u_iptvsharp?udpxy=$UDPXY"
fi

cat <<EOF

================ 安装完成 ================
  节点：$LAN_IP:$PORT
  IPTV 专网：$ETH1_IF = $LEASE_IP/16（网关 $LEASE_GW，租约动态）
  专网路由：${IPTV_NETS// /, } via 租约网关（随租约自动维护）
  管理：iptv-spider / iptv-spider-status
  EPG：http://$LAN_IP:$PORT/api/epg?daysAgo=$CATCHUP_DAYS
  TiviMate：$m3u_tivimate
  IPTV#：$m3u_iptvsharp
==========================================
EOF
