#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "请使用 root 用户运行安装程序。"
  exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DEFAULT_DIR=/opt/sh-iptv-spider
FIXED_AUTH_HOST='222.68.208.73:7001'

ask() {
  local prompt=$1 default=${2-} value
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " value
    printf '%s' "${value:-$default}"
  else
    read -r -p "$prompt: " value
    printf '%s' "$value"
  fi
}

ask_secret() {
  local prompt=$1 value
  read -r -s -p "$prompt: " value
  printf '\n' >&2
  printf '%s' "$value"
}

yaml_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

require_value() {
  if [ -z "$2" ]; then
    echo "$1不能为空。"
    exit 1
  fi
}

validate_install_dir() {
  case "$1" in
    /*) ;;
    *) echo '安装目录必须是绝对路径。'; exit 1 ;;
  esac
  case "$1" in
    /|/root|/opt|/usr|/usr/local|/etc|/var|/home)
      echo "安装目录范围过大，拒绝使用：$1"
      exit 1
      ;;
  esac
}

yaml_value() {
  local key=$1 file=$2
  sed -n "s/^[[:space:]]*${key}:[[:space:]]*\"\(.*\)\"[[:space:]]*$/\1/p" "$file" | tail -n 1
}

config_value() {
  local key=$1 file=$2
  sed -n "s/^[[:space:]]*${key}:[[:space:]]*'\([^']*\)'[[:space:]]*$/\1/p" "$file" | tail -n 1
}

sql_escape() {
  printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/''/g"
}

install_package_files() {
  install -d -m 0755 "$APP_DIR"
  tar -C "$SCRIPT_DIR" --exclude='./config.yaml' --exclude='./.git' -cf - . | tar -C "$APP_DIR" -xf -
  if [ -x "$APP_DIR/bin/iptv-spider-linux-amd64" ] && [ "$(uname -m)" = 'x86_64' ]; then
    install -m 0755 "$APP_DIR/bin/iptv-spider-linux-amd64" "$APP_DIR/iptv-spider"
  elif command -v go >/dev/null 2>&1; then
    (cd "$APP_DIR" && go build -buildvcs=false -o iptv-spider .)
  else
    echo '安装包中没有兼容的程序，系统也未安装 Go，无法继续。'
    return 1
  fi
  install -m 0755 "$APP_DIR/uninstall.sh" /usr/local/sbin/iptv-spider-uninstall
  install -m 0755 "$APP_DIR/status.sh" /usr/local/sbin/iptv-spider-status
  install -m 0755 "$APP_DIR/manage.sh" /usr/local/sbin/iptv-spider
  sed "s|__INSTALL_DIR__|$APP_DIR|g" "$APP_DIR/systemd/iptv-spider.service" > /etc/systemd/system/iptv-spider.service
  systemctl daemon-reload
}

upgrade_existing() {
  local stamp backup
  stamp=$(date +%Y%m%d%H%M%S)
  backup="${APP_DIR}.upgrade-backup.${stamp}"
  echo "正在备份现有安装到 $backup ..."
  cp -a "$APP_DIR" "$backup"
  systemctl stop iptv-spider.service 2>/dev/null || true
  if ! install_package_files; then
    rm -rf "$APP_DIR"
    mv "$backup" "$APP_DIR"
    sed "s|__INSTALL_DIR__|$APP_DIR|g" "$APP_DIR/systemd/iptv-spider.service" > /etc/systemd/system/iptv-spider.service
    systemctl daemon-reload
    systemctl start iptv-spider.service 2>/dev/null || true
    echo '升级文件安装失败，已恢复原版本。'
    return 1
  fi
  chmod 600 "$APP_DIR/config.yaml"
  systemctl enable iptv-spider.service >/dev/null
  if ! systemctl restart iptv-spider.service || ! timeout 30 bash -c '
    stable=0
    while [ "$stable" -lt 5 ]; do
      if systemctl is-active --quiet iptv-spider.service; then
        stable=$((stable + 1))
      else
        stable=0
      fi
      sleep 1
    done
  '; then
    echo '新版本启动失败，正在回滚...'
    systemctl stop iptv-spider.service 2>/dev/null || true
    rm -rf "$APP_DIR"
    mv "$backup" "$APP_DIR"
    sed "s|__INSTALL_DIR__|$APP_DIR|g" "$APP_DIR/systemd/iptv-spider.service" > /etc/systemd/system/iptv-spider.service
    systemctl daemon-reload
    systemctl start iptv-spider.service
    echo '已恢复原版本。'
    return 1
  fi
  echo '覆盖升级完成。原 config.yaml、数据库和 IPTV 网络配置均已保留。'
  echo "升级前完整备份：$backup"
  echo '确认新版本稳定后可手工删除该备份目录。'
  echo
  /usr/local/sbin/iptv-spider-status || true
}

update_existing_stb_config() {
  local config_file=$APP_DIR/config.yaml backup
  backup="${config_file}.stb-backup.$(date +%Y%m%d%H%M%S)"
  cp -a "$config_file" "$backup"
  STB_UID=$(yaml_escape "$STB_UID")
  STB_MAC=$(yaml_escape "$STB_MAC")
  STB_SN=$(yaml_escape "$STB_SN")
  STB_IP=$(yaml_escape "$STB_IP")
  STB_TYPE=$(yaml_escape "$STB_TYPE")
  AUTH_HOST=$(yaml_escape "$AUTH_HOST")
  STB_PLANE_A_IP=$(yaml_escape "$STB_PLANE_A_IP")
  STB_PLANE_B_GATEWAY=$(yaml_escape "$STB_PLANE_B_GATEWAY")
  awk -v uid="$STB_UID" -v mac="$STB_MAC" -v sn="$STB_SN" \
    -v ip="$STB_IP" -v type="$STB_TYPE" -v auth_host="$AUTH_HOST" \
    -v plane_a_ip="$STB_PLANE_A_IP" -v plane_b_gateway="$STB_PLANE_B_GATEWAY" '
    /^stb:[[:space:]]*$/ { in_stb=1; print; next }
    in_stb && /^[^[:space:]]/ { in_stb=0 }
    in_stb && /^  uid:/ { print "  uid: '\''" uid "'\''"; next }
    in_stb && /^  mac:/ { print "  mac: '\''" mac "'\''"; next }
    in_stb && /^  sn:/ { print "  sn: '\''" sn "'\''"; next }
    in_stb && /^  ip:/ { print "  ip: '\''" ip "'\''"; next }
    in_stb && /^  type:/ { print "  type: '\''" type "'\''"; next }
    in_stb && /^  auth_host:/ { print "  auth_host: '\''" auth_host "'\''"; next }
    in_stb && /^  plane_a_ip:/ { print "  plane_a_ip: '\''" plane_a_ip "'\''"; next }
    in_stb && /^  plane_b_gateway:/ { print "  plane_b_gateway: '\''" plane_b_gateway "'\''"; next }
    { print }
  ' "$config_file" > "${config_file}.tmp"
  mv "${config_file}.tmp" "$config_file"
  echo "已更新机顶盒字段，原配置备份：$backup"
}

show_routeros_iptv_commands() {
  cat <<EOF

请在 RouterOS 持久化以下 IPTV Spider 三层出口配置：
/ip route add dst-address=218.83.0.0/16 gateway=${STB_PLANE_B_GATEWAY}%bridge_iptv comment="iptv-spider EPG via IPTV gateway"
/ip route add dst-address=222.68.0.0/16 gateway=${STB_PLANE_B_GATEWAY}%bridge_iptv comment="iptv-spider auth via IPTV gateway"
/ip route add dst-address=124.75.0.0/16 gateway=${STB_PLANE_B_GATEWAY}%bridge_iptv comment="iptv-spider auth CDN via IPTV gateway"
/ip firewall filter add chain=forward action=accept connection-state=new src-address=${STB_IP} dst-address=218.83.0.0/16 comment="iptv-spider CT EPG forwarding" place-before=0
/ip firewall filter add chain=forward action=accept connection-state=new src-address=${STB_IP} dst-address=222.68.0.0/16 comment="iptv-spider CT auth forwarding" place-before=0
/ip firewall filter add chain=forward action=accept connection-state=new src-address=${STB_IP} dst-address=124.75.0.0/16 comment="iptv-spider CT auth CDN forwarding" place-before=0
/ip firewall nat add chain=srcnat action=src-nat to-addresses=${ROUTEROS_IPTV_DHCP_IP} src-address=${STB_IP} dst-address=218.83.0.0/16 comment="iptv-spider CT EPG SNAT" place-before=0
/ip firewall nat add chain=srcnat action=src-nat to-addresses=${ROUTEROS_IPTV_DHCP_IP} src-address=${STB_IP} dst-address=222.68.0.0/16 comment="iptv-spider CT auth SNAT" place-before=0
/ip firewall nat add chain=srcnat action=src-nat to-addresses=${ROUTEROS_IPTV_DHCP_IP} src-address=${STB_IP} dst-address=124.75.0.0/16 comment="iptv-spider CT auth CDN SNAT" place-before=0

路由下一跳使用机顶盒抓包得到的 B 面网关；SNAT 地址使用 RouterOS 当前 bridge_iptv 的 DHCP 地址：${ROUTEROS_IPTV_DHCP_IP}。
EOF
}

configure_routeros_iptv_routes() {
  local route_command result dst comment
  if [ -z "${ROUTER_HOST:-}" ] || [ -z "${ROUTER_USER:-}" ] || [ -z "${STB_PLANE_B_GATEWAY:-}" ]; then
    echo 'RouterOS 登录信息或 IPTV 网关不完整，跳过自动添加 RouterOS IPTV 路由。'
    return 0
  fi
  if ! valid_ipv4 "$STB_PLANE_B_GATEWAY"; then
    echo "机顶盒 IPTV 网关格式无效，跳过 RouterOS 路由配置：$STB_PLANE_B_GATEWAY"
    return 0
  fi
  for dst in 218.83.0.0/16 222.68.0.0/16 124.75.0.0/16; do
    case "$dst" in
      218.83.0.0/16) comment='iptv-spider EPG via IPTV gateway' ;;
      222.68.0.0/16) comment='iptv-spider auth via IPTV gateway' ;;
      124.75.0.0/16) comment='iptv-spider auth CDN via IPTV gateway' ;;
    esac
    route_command=" :if ([:len [/ip route find comment=\"$comment\"]] = 0) do={ /ip route add dst-address=$dst gateway=${STB_PLANE_B_GATEWAY}%bridge_iptv comment=\"$comment\" } else={ /ip route set [/ip route find comment=\"$comment\"] gateway=${STB_PLANE_B_GATEWAY}%bridge_iptv }"
    if ! result=$(routeros_ssh_command "$route_command" 2>&1); then
      echo "RouterOS 路由配置失败（$dst）："
      printf '%s\n' "$result" | sed -n '1,3p'
      return 0
    fi
  done
  echo 'RouterOS IPTV 路由检查完成：已有规则已保留，缺失规则已自动添加。'
}

collect_routeros_iptv_ip() {
  if [ -n "${ROUTER_HOST:-}" ] && [ -n "${ROUTER_USER:-}" ]; then
    local detected query_error route_gateway
    query_error=$(mktemp /tmp/routeros-iptv-query.XXXXXX)
    detected=$(routeros_ssh_command '/ip dhcp-client get [find interface=bridge_iptv] address' 2>"$query_error" || true)
    detected=$(printf '%s' "$detected" | tr -d '\r' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1 || true)
    if valid_ipv4 "${detected:-}"; then
      ROUTEROS_IPTV_DHCP_IP=$detected
      rm -f "$query_error"
      echo "已从 RouterOS 自动检测 IPTV DHCP 地址：$ROUTEROS_IPTV_DHCP_IP"
      return 0
    fi
    route_gateway=$(ip route show 30.181.0.0/16 2>/dev/null | sed -n 's/.* via \([0-9.]*\) .*/\1/p' | head -n 1 || true)
    if valid_ipv4 "${route_gateway:-}"; then
      ROUTEROS_IPTV_DHCP_IP=$route_gateway
      rm -f "$query_error"
      echo "RouterOS DHCP 查询未返回地址，已从现有 IPTV 路由恢复：$ROUTEROS_IPTV_DHCP_IP"
      return 0
    fi
    echo '无法自动读取 RouterOS bridge_iptv DHCP 地址。'
    if [ -s "$query_error" ]; then
      echo 'RouterOS SSH 错误：'
      sed -n '1,3p' "$query_error"
    fi
    rm -f "$query_error"
  fi
  while :; do
    ROUTEROS_IPTV_DHCP_IP=$(ask 'RouterOS bridge_iptv 当前 IPTV DHCP 地址' "${ROUTEROS_IPTV_DHCP_IP:-}")
    if valid_ipv4 "$ROUTEROS_IPTV_DHCP_IP"; then
      return 0
    fi
    echo "RouterOS IPTV DHCP 地址格式无效：$ROUTEROS_IPTV_DHCP_IP"
  done
}

routeros_ssh_command() {
  local command=$1
  if [ -n "${ROUTER_PASSWORD:-}" ]; then
    SSHPASS="$ROUTER_PASSWORD" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -p "$ROUTER_PORT" "$ROUTER_USER@$ROUTER_HOST" "$command"
  else
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -i "$ROUTER_KEY" -p "$ROUTER_PORT" "$ROUTER_USER@$ROUTER_HOST" "$command"
  fi
}

install_routeros_sync() {
  local sync_conf=/etc/iptv-spider/routeros-sync.conf
  if [ -z "${ROUTER_KEY:-}" ]; then
    ROUTER_KEY=$(ask '自动同步使用的 RouterOS SSH 私钥路径（留空则不启用自动同步）' '')
    if [ -z "$ROUTER_KEY" ]; then
      echo '未配置 SSH 私钥，已跳过自动 RouterOS DHCP 同步。'
      echo '以后配置密钥后可手工创建 /etc/iptv-spider/routeros-sync.conf 并启用 timer。'
      return 0
    fi
    if [ ! -r "$ROUTER_KEY" ]; then
      echo "SSH 私钥无法读取：$ROUTER_KEY，已跳过自动同步。"
      return 0
    fi
  fi
  install -d -m 0755 /etc/iptv-spider /var/lib/iptv-spider
  cat > "$sync_conf" <<EOF
router_host=$(printf '%q' "$ROUTER_HOST")
router_port=$(printf '%q' "$ROUTER_PORT")
router_user=$(printf '%q' "$ROUTER_USER")
router_key=$(printf '%q' "${ROUTER_KEY:-}")
router_interface=bridge_iptv
ct_interface=eth1
ct_ip=$(printf '%q' "$STB_IP")
routes='218.83.0.0/16 222.68.0.0/16 124.75.0.0/16'
nat_comments='iptv-spider CT EPG SNAT|iptv-spider CT auth SNAT|iptv-spider CT auth CDN SNAT'
filter_comments='iptv-spider CT EPG forwarding|iptv-spider CT auth forwarding|iptv-spider CT auth CDN forwarding'
EOF
  echo 'router_password_mode=key' >> "$sync_conf"
  chmod 600 "$sync_conf"
  install -m 0755 "$SCRIPT_DIR/iptv-routeros-sync" /usr/local/sbin/iptv-routeros-sync
  install -m 0644 "$SCRIPT_DIR/systemd/iptv-routeros-sync.service" /etc/systemd/system/iptv-routeros-sync.service
  install -m 0644 "$SCRIPT_DIR/systemd/iptv-routeros-sync.timer" /etc/systemd/system/iptv-routeros-sync.timer
  systemctl daemon-reload
  systemctl enable --now iptv-routeros-sync.timer
  systemctl start iptv-routeros-sync.service || true
}

collect_stb_manual() {
  STB_UID=$(ask 'IPTV 账号 UID')
  STB_MAC=$(ask '机顶盒 MAC 地址')
  STB_SN=$(ask '机顶盒 SN 序列号')
  STB_TYPE=$(ask '机顶盒型号')
  AUTH_HOST="$FIXED_AUTH_HOST"
  STB_PLANE_A_IP=$(ask '机顶盒 A 面/LAN 地址（可留空）')
  STB_IP=$(ask '机顶盒 B 面/IPTV 专网地址')
  STB_PLANE_B_GATEWAY=$(ask '机顶盒 B 面网关（可留空）')
}

collect_stb_capture() {
  local probe output capture_ok answer auth_mode
  probe="$SCRIPT_DIR/bin/stb-probe-linux-amd64"
  if [ "$(uname -m)" != 'x86_64' ] || [ ! -x "$probe" ]; then
    echo '安装包中没有适用于当前 CPU 的 stb-probe 程序。'
    echo '请选择手工输入，或在 amd64 Debian/Ubuntu 主机上抓包。'
    return 1
  fi
  if ! command -v ssh >/dev/null 2>&1 || ! command -v scp >/dev/null 2>&1; then
    echo '正在安装抓包模块所需的 SSH 客户端...'
    apt-get update
    apt-get install -y --no-install-recommends openssh-client ca-certificates
  fi

  ROUTER_HOST=$(ask 'RouterOS 地址' '192.168.100.1')
  ROUTER_PORT=$(ask 'RouterOS SSH 端口' '1314')
  ROUTER_USER=$(ask 'RouterOS SSH 用户名' 'david_ni')
  auth_mode=$(ask 'RouterOS 登录方式：1=用户名和密码，2=SSH 私钥' '1')
  ROUTER_KEY=''
  ROUTER_PASSWORD=''
  case "$auth_mode" in
    2)
      ROUTER_KEY=$(ask 'SSH 私钥路径' '/root/.ssh/id_ed25519_routeros')
      if [ ! -r "$ROUTER_KEY" ]; then
        echo "SSH 私钥无法读取：$ROUTER_KEY"
        return 1
      fi
      ;;
    *)
      ROUTER_PASSWORD=$(ask_secret 'RouterOS SSH 密码')
      require_value 'RouterOS SSH 密码' "$ROUTER_PASSWORD"
      if ! command -v sshpass >/dev/null 2>&1; then
        echo '正在安装 RouterOS 密码登录组件...'
        apt-get update
        apt-get install -y --no-install-recommends sshpass
      fi
      export STB_PROBE_ROUTER_PASSWORD="$ROUTER_PASSWORD"
      ;;
  esac
  ROUTER_IFACE=$(ask '连接实体机顶盒的 RouterOS 物理端口' 'ether3_lan')
  CAPTURE_SECONDS=$(ask '抓包时长（秒）' '120')
  require_value 'RouterOS 地址' "$ROUTER_HOST"
  require_value 'RouterOS SSH 用户名' "$ROUTER_USER"
  require_value 'RouterOS 端口' "$ROUTER_IFACE"

  while :; do
    echo
    echo '抓包将在 RouterOS 的 IPTV 物理端口上运行。'
    echo '按回车并看到“抓包已开始”后，请立即重新启动实体机顶盒。'
    echo '等待机顶盒进入首页；抓包期间请勿中断安装程序。'
    read -r -p '确认已经准备好重启机顶盒后，按回车开始抓包... ' answer
    output=$(mktemp /tmp/stb-probe-result.XXXXXX)
    capture_ok=0
    echo
    echo '抓包已开始，请现在立即重启实体机顶盒。'
    if [ -n "$ROUTER_PASSWORD" ]; then
      "$probe" \
        -router "$ROUTER_HOST" -router-port "$ROUTER_PORT" \
        -router-user "$ROUTER_USER" -router-password-env STB_PROBE_ROUTER_PASSWORD \
        -interface "$ROUTER_IFACE" -duration "$CAPTURE_SECONDS" >"$output" 2>&1 || capture_ok=$?
    else
      "$probe" \
        -router "$ROUTER_HOST" -router-port "$ROUTER_PORT" \
        -router-user "$ROUTER_USER" -router-key "$ROUTER_KEY" \
        -interface "$ROUTER_IFACE" -duration "$CAPTURE_SECONDS" >"$output" 2>&1 || capture_ok=$?
    fi

    echo
    echo '检测到的机顶盒数据：'
    echo '------------------------------------------------------------'
    cat "$output"
    echo '------------------------------------------------------------'
    if [ "$capture_ok" -eq 0 ]; then
      STB_UID=$(yaml_value uid "$output")
      STB_MAC=$(yaml_value mac "$output")
      STB_SN=$(yaml_value sn "$output")
      STB_TYPE=$(yaml_value type "$output")
      AUTH_HOST=$(yaml_value auth_host "$output")
      STB_PLANE_A_IP=$(yaml_value plane_a_ip "$output")
      STB_IP=$(yaml_value plane_b_ip "$output")
      STB_PLANE_B_GATEWAY=$(yaml_value plane_b_gateway "$output")
    fi
    rm -f "$output"

    if [ "$capture_ok" -eq 0 ] && [ -n "$STB_UID" ] && [ -n "$STB_MAC" ] && [ -n "$STB_SN" ] && [ -n "$STB_IP" ] && [ -n "$AUTH_HOST" ]; then
      echo '抓包完成，以上数据将自动写入 config.yaml。'
      unset STB_PROBE_ROUTER_PASSWORD
      return 0
    fi
    echo '本次抓包没有取得全部必需的认证字段。'
    answer=$(ask '输入 R 重新抓包，或输入 M 改为手工填写' 'R')
    case "$answer" in
      [Mm]*) unset STB_PROBE_ROUTER_PASSWORD; return 1 ;;
    esac
  done
}

show_epg_stats() {
  local attempt count stats total_channels epg_channels programmes first_time last_time warnings log_file fetch_complete
  echo
  echo '正在等待首次 EPG 抓取完成（最多 3 分钟）...'
  count=0
  fetch_complete=0
  log_file="$APP_DIR/latest_log"
  for attempt in $(seq 1 36); do
    if ! systemctl is-active --quiet iptv-spider; then
      echo 'IPTV Spider 服务未运行，无法统计 EPG。'
      systemctl status iptv-spider --no-pager --lines=10 || true
      return 1
    fi
    count=$(MYSQL_PWD="$MYSQL_PASSWORD" mysql --batch --skip-column-names \
      -h "$MYSQL_HOST" -u "$MYSQL_USER" "$MYSQL_DB" \
      -e 'SELECT COUNT(*) FROM epg_details;' 2>/dev/null || printf '0')
    if [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt 0 ] && [ -f "$log_file" ] && grep -q '更新节目信息列表完成' "$log_file"; then
      fetch_complete=1
      break
    fi
    sleep 5
  done
  if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -eq 0 ]; then
    echo '等待超时：数据库中尚无 EPG 节目，请检查服务日志：'
    echo "  journalctl -u iptv-spider -n 100 --no-pager"
    return 1
  fi
	if [ "$fetch_complete" -eq 0 ]; then
		echo '等待超时：EPG 抓取仍在进行，以下显示当前统计。'
	fi

  total_channels=$(MYSQL_PWD="$MYSQL_PASSWORD" mysql --batch --skip-column-names \
    -h "$MYSQL_HOST" -u "$MYSQL_USER" "$MYSQL_DB" \
    -e 'SELECT COUNT(*) FROM channel_infos;' 2>/dev/null || printf '0')
  stats=$(MYSQL_PWD="$MYSQL_PASSWORD" mysql --batch --skip-column-names \
    -h "$MYSQL_HOST" -u "$MYSQL_USER" "$MYSQL_DB" \
    -e "SELECT COUNT(DISTINCT comm_name), COUNT(*), DATE_FORMAT(FROM_UNIXTIME(MIN(start_time)/1000),'%Y-%m-%d %H:%i'), DATE_FORMAT(FROM_UNIXTIME(MAX(end_time)/1000),'%Y-%m-%d %H:%i') FROM epg_details;" 2>/dev/null || true)
  IFS=$'\t' read -r epg_channels programmes first_time last_time <<< "$stats"
  warnings=0
  if [ -f "$log_file" ]; then
    warnings=$(grep -c 'FetchChannelProg Err' "$log_file" 2>/dev/null || true)
  fi
  echo 'EPG 抓取统计：'
  echo "  频道记录数：${total_channels:-0}"
  echo "  已有节目单频道：${epg_channels:-0}"
  echo "  节目总数：${programmes:-0}"
  echo "  覆盖时间：${first_time:-未知} 至 ${last_time:-未知}"
  echo "  本次日志抓取警告：${warnings:-0}"
}

valid_ipv4() {
  local ip=$1 part
  local -a parts
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a parts <<< "$ip"
  for part in "${parts[@]}"; do
    [ "$part" -ge 0 ] && [ "$part" -le 255 ] || return 1
  done
}

configure_iptv_interface() {
  local answer interfaces_file=/etc/network/interfaces tmp backup existing_iptv_ip
  existing_iptv_ip=$(ip -4 -o addr show dev eth1 scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
  if valid_ipv4 "${existing_iptv_ip:-}" && [ "$existing_iptv_ip" != "$STB_IP" ]; then
    echo "检测到前置程序已配置 eth1 地址：$existing_iptv_ip"
    echo "抓包得到的机顶盒地址为 $STB_IP；回放和认证将使用 CT 自身地址 $existing_iptv_ip。"
    STB_IP=$existing_iptv_ip
    if [ -f "$APP_DIR/config.yaml" ]; then
      sed -i "0,/^  ip: .*/s//  ip: '$STB_IP'/" "$APP_DIR/config.yaml"
    fi
  fi
  collect_routeros_iptv_ip
  configure_routeros_iptv_routes
  echo
  echo 'IPTV 专网配置'
  echo "即将使用 CT 当前 eth1 地址 $STB_IP/16 配置 IPTV 专网。"
  echo '实体机顶盒和本机不能同时使用同一个专网 IP。'
  while :; do
    answer=$(ask '请关闭实体机顶盒；关闭后输入 YES，输入 SKIP 可暂不配置')
    case "$answer" in
      YES|yes|Yes) break ;;
      SKIP|skip|Skip)
        echo '已跳过 eth1 专网配置。稍后请在关闭机顶盒后手工配置。'
        return 0
        ;;
      *) echo '请输入 YES 确认机顶盒已经关闭，或输入 SKIP 跳过。' ;;
    esac
  done

  if [ ! -e /sys/class/net/eth1 ]; then
    echo '未找到 eth1，无法自动配置 IPTV 专网；安装的其他部分不受影响。'
    return 0
  fi
  if ! valid_ipv4 "$STB_IP"; then
    echo "抓到的 IPTV 专网地址格式无效：$STB_IP"
    return 0
  fi
  if grep -Eq '^[[:space:]]*iface[[:space:]]+eth1[[:space:]]+inet' "$interfaces_file" && \
     ! grep -q '^# BEGIN IPTV-SPIDER ETH1$' "$interfaces_file"; then
    echo '/etc/network/interfaces 中已经存在非本程序创建的 eth1 配置。'
    echo '为避免覆盖用户配置，已跳过自动配置，请手工检查 eth1。'
    return 0
  fi

  backup="${interfaces_file}.iptv-spider.$(date +%Y%m%d%H%M%S).bak"
  cp -a "$interfaces_file" "$backup"
  tmp=$(mktemp /tmp/interfaces.XXXXXX)
  awk '
    $0 == "# BEGIN IPTV-SPIDER ETH1" {skip=1; next}
    $0 == "# END IPTV-SPIDER ETH1" {skip=0; next}
    !skip {print}
  ' "$interfaces_file" > "$tmp"
  {
    cat "$tmp"
    printf '\n# BEGIN IPTV-SPIDER ETH1\n'
    printf 'auto eth1\n'
    printf 'iface eth1 inet static\n'
    printf '\taddress %s/16\n' "$STB_IP"
    printf '\tup ip route replace 218.83.0.0/16 via %s dev eth1 src %s\n' "$ROUTEROS_IPTV_DHCP_IP" "$STB_IP"
    printf '\tup ip route replace 222.68.0.0/16 via %s dev eth1 src %s\n' "$ROUTEROS_IPTV_DHCP_IP" "$STB_IP"
    printf '\tup ip route replace 124.75.0.0/16 via %s dev eth1 src %s\n' "$ROUTEROS_IPTV_DHCP_IP" "$STB_IP"
    printf '# END IPTV-SPIDER ETH1\n'
  } > "$interfaces_file"
  rm -f "$tmp"

  ip link set eth1 up
  ip -4 addr flush dev eth1 scope global
  ip addr add "$STB_IP/16" dev eth1
  ip route replace "218.83.0.0/16" via "$ROUTEROS_IPTV_DHCP_IP" dev eth1 src "$STB_IP"
  ip route replace "222.68.0.0/16" via "$ROUTEROS_IPTV_DHCP_IP" dev eth1 src "$STB_IP"
  ip route replace "124.75.0.0/16" via "$ROUTEROS_IPTV_DHCP_IP" dev eth1 src "$STB_IP"
  install_routeros_sync
  unset STB_PROBE_ROUTER_PASSWORD ROUTER_PASSWORD
  echo "eth1 已配置为 $STB_IP/16，并经 RouterOS $ROUTEROS_IPTV_DHCP_IP 添加 EPG/认证专网路由；未重启网络，当前 SSH 连接不受影响。"
  echo "原网络配置备份：$backup"
  systemctl restart iptv-spider
}

echo '上海电信 IPTV Spider 安装程序'
echo '生成的配置包含 IPTV 认证信息；本安装程序不会上传这些信息。'

APP_DIR=$(ask '安装目录' "$DEFAULT_DIR")
validate_install_dir "$APP_DIR"
if [ -f "$APP_DIR/config.yaml" ]; then
  echo
  echo "检测到现有安装：$APP_DIR"
  EXISTING_ACTION=$(ask '输入 U 覆盖升级并保留配置，输入 Q 退出' 'U')
  case "$EXISTING_ACTION" in
    [Uu]*)
      export DEBIAN_FRONTEND=noninteractive
      if ! command -v curl >/dev/null 2>&1 || ! command -v ssh >/dev/null 2>&1 || ! command -v mysql >/dev/null 2>&1; then
        apt-get update
        apt-get install -y --no-install-recommends ca-certificates curl openssh-client mariadb-client
      fi
      echo
      echo '覆盖安装必须重新抓包机顶盒；原有数据库、回放配置和服务端口将保留。'
      collect_stb_capture || { echo '覆盖安装因抓包失败而取消，未修改现有安装。'; exit 1; }
      update_existing_stb_config
      upgrade_existing
      configure_iptv_interface
      show_routeros_iptv_commands
      exit $?
      ;;
    *) echo '安装已取消。'; exit 0 ;;
  esac
fi
PORT=$(ask '服务端口' '8888')
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo '服务端口必须是 1 到 65535 之间的整数。'
  exit 1
fi
LAN_IP=$(ask '用于节目源、EPG 和 Logo 的服务器 LAN 地址')
require_value '服务器 LAN 地址' "$LAN_IP"

echo
echo '抓取模块与机顶盒配置'
echo '  1) 手工输入机顶盒信息'
echo '  2) 通过 RouterOS 自动抓取机顶盒认证信息'
STB_MODE=$(ask '请选择机顶盒信息获取方式' '2')
case "$STB_MODE" in
  2|[Cc]*) collect_stb_capture || collect_stb_manual ;;
  *) collect_stb_manual ;;
esac
require_value 'IPTV 账号 UID' "$STB_UID"
require_value '机顶盒 MAC 地址' "$STB_MAC"
require_value '机顶盒 SN 序列号' "$STB_SN"
require_value '机顶盒 IPTV 专网地址' "$STB_IP"

echo
echo '直播与回放配置'
SOURCE_M3U=$(ask '已有直播 M3U 地址（可留空，留空则使用项目自身输出）')
UDPXY=$(ask 'udpxy/msd_lite 地址（可留空，格式：主机:端口）')
CATCHUP_DAYS=$(ask '回放天数' '7')
if ! [[ "$CATCHUP_DAYS" =~ ^[0-9]+$ ]] || [ "$CATCHUP_DAYS" -lt 1 ] || [ "$CATCHUP_DAYS" -gt 7 ]; then
  echo '回放天数必须是 1 到 7 之间的整数。'
  exit 1
fi
RELAY_CLIENTS=$(ask '需要中继的客户端地址（可留空，多个地址用逗号分隔）')

echo
echo 'MySQL / MariaDB 配置'
MYSQL_HOST=$(ask 'MySQL 主机' '127.0.0.1')
MYSQL_DB=$(ask '数据库名称' 'iptv')
MYSQL_USER=$(ask '数据库用户名' 'iptv')
MYSQL_PASSWORD=$(ask_secret '数据库密码')
require_value '数据库密码' "$MYSQL_PASSWORD"
if ! [[ "$MYSQL_DB" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo '数据库名称只能包含字母、数字和下划线。'
  exit 1
fi
if ! [[ "$MYSQL_USER" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo '数据库用户名只能包含字母、数字、下划线、点和连字符。'
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl openssh-client mariadb-client mariadb-server

if [ "$MYSQL_HOST" = '127.0.0.1' ] || [ "$MYSQL_HOST" = 'localhost' ]; then
  mysql_user_sql=$(sql_escape "$MYSQL_USER")
  mysql_password_sql=$(sql_escape "$MYSQL_PASSWORD")
  mariadb -e "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  for mysql_account_host in localhost 127.0.0.1 %; do
    mariadb -e "CREATE USER IF NOT EXISTS '$mysql_user_sql'@'$mysql_account_host' IDENTIFIED BY '$mysql_password_sql';"
    mariadb -e "ALTER USER '$mysql_user_sql'@'$mysql_account_host' IDENTIFIED BY '$mysql_password_sql';"
    mariadb -e "GRANT ALL PRIVILEGES ON \`$MYSQL_DB\`.* TO '$mysql_user_sql'@'$mysql_account_host';"
  done
  mariadb -e 'FLUSH PRIVILEGES;'
fi

install_package_files

relay_yaml='[]'
if [ -n "$RELAY_CLIENTS" ]; then
  relay_yaml='['
  IFS=',' read -r -a relay_items <<< "$RELAY_CLIENTS"
  for relay in "${relay_items[@]}"; do
    relay=$(printf '%s' "$relay" | xargs)
    [ -n "$relay" ] && relay_yaml+="'$(yaml_escape "$relay")',"
  done
  relay_yaml=${relay_yaml%,}']'
fi

{
  printf "system:\n  env: 'release'\n  addr: '0.0.0.0:%s'\n  db-type: 'mysql'\n  oss-type: ''\n\n" "$PORT"
  printf "stb:\n  uid: '%s'\n  mac: '%s'\n  sn: '%s'\n  ip: '%s'\n  type: '%s'\n  auth_host: '%s'\n  plane_a_ip: '%s'\n  plane_b_gateway: '%s'\n\n" \
    "$(yaml_escape "$STB_UID")" "$(yaml_escape "$STB_MAC")" "$(yaml_escape "$STB_SN")" \
    "$(yaml_escape "$STB_IP")" "$(yaml_escape "$STB_TYPE")" "$(yaml_escape "$AUTH_HOST")" \
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

systemctl enable --now iptv-spider
configure_iptv_interface
show_epg_stats || true

echo
echo '安装完成。'
echo "通用播放源：http://$LAN_IP:$PORT/tv.m3u"
echo "IPTV# 专用播放源：http://$LAN_IP:$PORT/iptvsharp.m3u"
echo "节目单 EPG：http://$LAN_IP:$PORT/api/epg?daysAgo=$CATCHUP_DAYS"
echo "Logo 示例：http://$LAN_IP:$PORT/iptvlogos/CGTN.png"
echo '日常管理：iptv-spider'
echo
/usr/local/sbin/iptv-spider-status || true
