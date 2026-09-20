#!/usr/bin/env bash
# pve-iptv-dhcp-create.sh - 一键创建全新 IPTV CT 并完成 DHCP-direct 安装
#
# 在 Proxmox VE 主机以 root 运行。两种用法：
#   A. 交互向导（推荐）：不带 --answers 直接运行，自动扫描空闲 CT 号/管理 IP
#      作为默认值，可回车采用或手工输入；输入冲突会提示后重新输入；并引导
#      选择"机顶盒抓包 / 手工填写"生成安装参数文件（向导抓包模式还会询问
#      RouterOS 连接参数，并把私钥推送到容器内供自动抓包使用）。
#   B. 参数化（脚本化）：--answers/--vmid/--mgmt-ip ... 全部显式给出，不交互。
#
# 流程：
#   0. 参数与向导（CT 号/IP 冲突校验）
#   1. PVE 侧：持久化 IPTV VLAN 桥（写 /etc/network/interfaces.d，可选运行态补建）
#   2. pct create 全新 Debian12 CT（eth0=管理网静态 / eth1=IPTV 桥、不带 ip=、固定 MAC）
#   3. 注入 SSH 公钥、上传参数文件与发行包
#   4. 在 CT 内执行 install-dhcp.sh（网络 + 抓包/手工机顶盒参数 + 应用 + 数据库 + 验证）
#
# 常用参数（方式 B）：
#   --answers <file>            安装参数文件（shell KEY=value；缺省走交互向导）
#   --vmid <n>                  容器 ID（缺省扫描空闲建议值，冲突可重输）
#   --hostname iptv-spider
#   --mgmt-bridge vmbr0 --mgmt-gw 192.168.100.1
#   --mgmt-ip <ip>              管理网 IP（缺省取 answers 的 LAN_IP，再自动扫描建议值）
#   --iptv-bridge vmbr0v85 --iptv-uplink nic1 --iptv-vlan 85
#   --eth1-mac <mac>            固定 MAC；与 answers 的 DHCP_DUID 必须成对（续租约）
#   --template <pve卷:vztmpl/..>  缺省自动查找 Debian 12 模板
#   --storage local-lvm --mem 2048 --disk 16 --cores 2
#   --ssh-pubkey <file>         注入 CT root 的 SSH 公钥（可选）
#   --root-password <pw>        设置 CT root 密码并允许 SSH root 登录（可选；
#                               向导里可直接输入；留空则仅公钥登录）
#   --routeros-key <file>       STB_MODE=capture 且私钥登录时，把本机 RouterOS
#                               SSH 私钥推送到容器 /root/.ssh/id_ed25519_routeros
#   --pkg-dir <dir>             本地应用发行目录；缺省自动使用本仓库 app/（自包含，无需外部仓库）；无 app/ 时 CT 内走本仓库 GitHub Release
#   --bootstrap <install-dhcp.sh>  缺省与本脚本同目录
#   --destroy-existing          同 vmid 已存在时先停止并销毁（危险）
#   --apply-live                桥不存在时执行运行态补建（一般只需持久化）
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo '请在 PVE Shell 以 root 运行。' >&2; exit 1; }
command -v pct >/dev/null 2>&1 || { echo '未检测到 pct，此脚本必须运行在 Proxmox VE 主机。' >&2; exit 1; }

ANSWERS=''
VMID=''
HOSTNAME=''
MGMT_BRIDGE=vmbr0
MGMT_GW=''
MGMT_IP=''
IPTV_BRIDGE=vmbr0v85
IPTV_UPLINK=nic1
IPTV_VLAN=85
ETH1_MAC=''
TEMPLATE=''
STORAGE=local-lvm
MEM=2048
DISK=16
CORES=2
SSH_PUBKEY=''
ROOT_PASSWORD=''
PKG_DIR=''
DESTROY_EXISTING=0
APPLY_LIVE=0
BOOTSTRAP=''
STB_MODE=''
ROUTER_KEY_PVE=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --answers) ANSWERS=$2; shift 2 ;;
    --vmid) VMID=$2; shift 2 ;;
    --hostname) HOSTNAME=$2; shift 2 ;;
    --mgmt-bridge) MGMT_BRIDGE=$2; shift 2 ;;
    --mgmt-gw) MGMT_GW=$2; shift 2 ;;
    --mgmt-ip) MGMT_IP=$2; shift 2 ;;
    --iptv-bridge) IPTV_BRIDGE=$2; shift 2 ;;
    --iptv-uplink) IPTV_UPLINK=$2; shift 2 ;;
    --iptv-vlan) IPTV_VLAN=$2; shift 2 ;;
    --eth1-mac) ETH1_MAC=$2; shift 2 ;;
    --template) TEMPLATE=$2; shift 2 ;;
    --storage) STORAGE=$2; shift 2 ;;
    --mem) MEM=$2; shift 2 ;;
    --disk) DISK=$2; shift 2 ;;
    --cores) CORES=$2; shift 2 ;;
    --ssh-pubkey) SSH_PUBKEY=$2; shift 2 ;;
    --root-password) ROOT_PASSWORD=$2; shift 2 ;;
    --routeros-key) ROUTER_KEY_PVE=$2; shift 2 ;;
    --pkg-dir) PKG_DIR=$2; shift 2 ;;
    --bootstrap) BOOTSTRAP=$2; shift 2 ;;
    --destroy-existing) DESTROY_EXISTING=1; shift ;;
    --apply-live) APPLY_LIVE=1; shift ;;
    -h|--help) sed -n '3,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done

HOSTNAME=${HOSTNAME:-iptv-spider}
MGMT_GW=${MGMT_GW:-192.168.100.1}

valid_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local p
  IFS=. read -r -a p <<< "$1"
  for part in "${p[@]}"; do
    [ "$part" -ge 0 ] && [ "$part" -le 255 ] || return 1
  done
}
is_tty() { [ -t 0 ]; }
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
  IFS= read -rs v || v=''
  printf '\n' >&2
  printf '%s' "$v"
}
gen_password() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true; }

# ------------------------------------------------------------- 扫描/校验 -----
is_ct_taken() { pct config "$1" >/dev/null 2>&1 || qm config "$1" >/dev/null 2>&1; }
next_free_vmid() {
  local n=${1:-100}
  while is_ct_taken "$n"; do n=$((n + 1)); done
  echo "$n"
}

# 占用检查：ping / neigh / 各 CT-VM 配置里已用的管理 IP
is_ip_taken() {
  local ip=$1 ignore=${2:-} c
  ping -c1 -W1 "$ip" >/dev/null 2>&1 && return 0
  ip neigh show "$ip" 2>/dev/null | grep -Eqi '\b(REACHABLE|STALE|DELAY|PROBE)\b' && return 0
  for c in $(pct list 2>/dev/null | awk 'NR>1{print $1}'); do
    [ -n "$ignore" ] && [ "$c" = "$ignore" ] && continue
    pct config "$c" 2>/dev/null | grep -Eq "net[0-9]+: .*ip=$ip/" && return 0
  done
  for c in $(qm list 2>/dev/null | awk 'NR>1{print $1}'); do
    [ -n "$ignore" ] && [ "$c" = "$ignore" ] && continue
    qm config "$c" 2>/dev/null | grep -Eq "ipconfig[0-9]+: .*ip=$ip/" && return 0
  done
  return 1
}
next_free_ip() {
  local base=$1 start=${2:-90} n ip
  for ((n = start; n < 255; n++)); do
    ip="$base.$n"
    is_ip_taken "$ip" || { echo "$ip"; return 0; }
  done
  return 1
}

resolve_vmid() {
  while :; do
    if [ -z "$VMID" ]; then
      if is_tty; then
        VMID=$(ask '容器 CT 号' "$(next_free_vmid 100)")
      else
        echo '缺少 --vmid，且无交互终端。' >&2
        exit 1
      fi
      continue
    fi
    [[ "$VMID" =~ ^[0-9]+$ ]] || { echo "CT 号必须是数字：$VMID" >&2; VMID=''; continue; }
    if is_ct_taken "$VMID"; then
      if [ "$DESTROY_EXISTING" -eq 1 ]; then
        return 0
      fi
      echo "CT/VM 号 $VMID 已被占用，请换一个（加 --destroy-existing 可覆盖）。" >&2
      VMID=''
      is_tty || exit 1
      continue
    fi
    return 0
  done
}

resolve_mgmt_ip() {
  if [ -z "$MGMT_IP" ] && [ -n "$ANSWERS" ] && [ -f "$ANSWERS" ]; then
    MGMT_IP=$(sed -n 's/^LAN_IP=\(.*\)$/\1/p' "$ANSWERS" | tail -n1)
  fi
  while :; do
    if [ -z "$MGMT_IP" ]; then
      if is_tty; then
        local base sug
        base=$(printf '%s' "$MGMT_GW" | cut -d. -f1-3)
        sug=$(next_free_ip "$base" 90 || true)
        MGMT_IP=$(ask '容器管理网 IP' "${sug:-}")
      else
        echo '缺少管理网 IP（--mgmt-ip 或 answers 的 LAN_IP），且无交互终端。' >&2
        exit 1
      fi
      continue
    fi
    valid_ipv4 "$MGMT_IP" || { echo "管理网 IP 无效：$MGMT_IP" >&2; MGMT_IP=''; continue; }
    if is_ip_taken "$MGMT_IP" "$VMID"; then
      echo "管理网 IP $MGMT_IP 已被占用（ping/邻居/现有 CT-VM 配置），请换一个。" >&2
      MGMT_IP=''
      is_tty || exit 1
      continue
    fi
    return 0
  done
}

# ------------------------------------------------ 交互向导（生成 answers）----
wizard_make_answers() {
  local wanswer d mode udpxy dbpass ans auth_mode
  log '=== 交互安装向导 ==='
  resolve_vmid
  resolve_mgmt_ip
  HOSTNAME=$(ask '容器主机名' "$HOSTNAME")
  echo 'SSH root 登录（默认已允许 root 公钥登录；如需密码登录请设置密码）：'
  ROOT_PASSWORD=$(ask_secret 'CT root 密码（留空=不设置，仅公钥登录）')
  echo
  echo '机顶盒认证参数获取方式：'
  echo '  1) RouterOS 抓包（推荐：全新安装除专网 IP 外都自动抓取填入）'
  echo '  2) 手工填写'
  mode=$(ask '请选择' '1')
  case "$mode" in
    2|[Mm]*)
      STB_MODE=manual
      STB_UID=$(ask 'IPTV 账号 UID')
      STB_MAC=$(ask '机顶盒 MAC')
      STB_SN=$(ask '机顶盒 SN')
      STB_TYPE=$(ask '机顶盒型号' 'B860A')
      STB_PLANE_A_IP=$(ask 'A 面/LAN 地址（可留空）' '')
      STB_PLANE_B_GATEWAY=$(ask 'B 面网关（可留空）' '')
      ;;
    *)
      STB_MODE=capture
      ROUTER_PASSWORD=''
      echo
      echo '下面只需先登记 RouterOS 连接信息，真正抓包不会现在开始：'
      echo '抓包会在【新 CT 创建、专网 DHCP 就绪、应用包就位之后】自动进行'
      echo '（预计几分钟；到时会再次提示，请把机顶盒断电→上电重启一次）。'
      echo '请确保实体机顶盒已接在 RouterOS 物理口并保持通电待机。'
      echo
      ROUTER_HOST=$(ask 'RouterOS 地址' '192.168.100.1')
      ROUTER_PORT=$(ask 'RouterOS SSH 端口' '1314')
      ROUTER_USER=$(ask 'RouterOS SSH 用户名' 'david_ni')
      auth_mode=$(ask 'RouterOS 登录：1=SSH 私钥（推荐） 2=用户名密码' '1')
      if [ "$auth_mode" = 2 ]; then
        ROUTER_AUTH=password
        ROUTER_PASSWORD=$(ask_secret 'RouterOS SSH 密码')
        ROUTER_KEY=''
        ROUTER_KEY_PVE=''
      else
        ROUTER_KEY_PVE=$(ask 'RouterOS 私钥（本机路径，留空改用密码）' '/root/.ssh/id_ed25519_bastion')
        if [ -z "$ROUTER_KEY_PVE" ] || [ ! -f "$ROUTER_KEY_PVE" ]; then
          echo '私钥文件不可用，改用用户名密码登录。' >&2
          ROUTER_AUTH=password
          ROUTER_PASSWORD=$(ask_secret 'RouterOS SSH 密码')
          ROUTER_KEY=''
          ROUTER_KEY_PVE=''
        else
          ROUTER_AUTH=key
          ROUTER_KEY=/root/.ssh/id_ed25519_routeros
        fi
      fi
      ROUTER_IFACE=$(ask '连接实体机顶盒的 RouterOS 物理端口' 'ether3_lan')
      CAPTURE_SECONDS=$(ask '抓包时长（秒）' '120')
      ;;
  esac
  echo '直播/回放相关（可留空，之后可改 /opt/sh-iptv-spider/config.yaml）'
  udpxy=$(ask 'udpxy/msd_lite 直播转换地址，如 192.168.100.51:4022（可留空）' '')
  CATCHUP_DAYS=$(ask '回放天数' '7')
  dbpass=$(ask_secret '本机 MariaDB 密码（留空自动生成）')
  [ -n "$dbpass" ] || dbpass=$(gen_password)
  wanswer=$(mktemp /tmp/iptv-answers.XXXXXX)
  {
    printf "APP_DIR=/opt/sh-iptv-spider\nPORT=8888\nLAN_IP=%s\nETH1_IF=eth1\n" "$MGMT_IP"
    if [ "$STB_MODE" = manual ]; then
      printf "STB_MODE=manual\nSTB_UID=%q\nSTB_MAC=%q\nSTB_SN=%q\nSTB_TYPE=%q\nSTB_AUTH_HOST='222.68.208.73:7001'\nSTB_PLANE_A_IP=%q\nSTB_PLANE_B_GATEWAY=%q\n" \
        "$STB_UID" "$STB_MAC" "$STB_SN" "$STB_TYPE" "$STB_PLANE_A_IP" "$STB_PLANE_B_GATEWAY"
    else
      printf "STB_MODE=capture\nROUTER_PRESET=1\nSTB_AUTH_HOST='222.68.208.73:7001'\n"
      printf "ROUTER_HOST=%q\nROUTER_PORT=%q\nROUTER_USER=%q\nROUTER_AUTH=%s\nROUTER_KEY=%q\nROUTER_PASSWORD=%q\nROUTER_IFACE=%q\nCAPTURE_SECONDS=%s\n" \
        "$ROUTER_HOST" "$ROUTER_PORT" "$ROUTER_USER" "$ROUTER_AUTH" "$ROUTER_KEY" "$ROUTER_PASSWORD" "$ROUTER_IFACE" "$CAPTURE_SECONDS"
    fi
    printf "SOURCE_M3U=\nUDPXY='%s'\nCATCHUP_DAYS=%s\nRELAY_CLIENTS=\n" "$udpxy" "$CATCHUP_DAYS"
    printf "MYSQL_HOST=127.0.0.1\nMYSQL_DB=iptv\nMYSQL_USER=iptv\nMYSQL_PASSWORD=%q\n" "$dbpass"
    printf "ROOT_PASSWORD=%q\n" "$ROOT_PASSWORD"
    printf "INSTALL_SOURCE=auto\nVERSION=1.2.3\nREPO_TAG=v0.3.2\nREPOSITORY=driftbottle61/iptv-spider-pve\n"
  } > "$wanswer"
  chmod 600 "$wanswer"
  ANSWERS_TMP=$wanswer
  ANSWERS=$wanswer
  trap 'rm -f "$ANSWERS_TMP"' EXIT
  ok "已生成安装参数：$wanswer（STB 获取方式=$STB_MODE）"
  ok '安装开始后参数会另存一份到 /root/install-dhcp.conf 供复用'
  echo
  log '接下来将自动执行：'
  ok '1) 持久化 IPTV 桥，pct create 全新 CT，注入 SSH 公钥/密码'
  ok '2) CT 内 eth1 走 DHCP 获取专网租约，下载应用发行包'
  if [ "$STB_MODE" = capture ]; then
    ok "3) 【机顶盒抓包】自动开始（约 ${CAPTURE_SECONDS:-120} 秒）——屏幕提示后请把实体机顶盒断电→上电重启"
    ok '4) 安装 MariaDB、写 config.yaml、启动服务、EPG/直连验证'
  else
    ok '3) 安装 MariaDB、写 config.yaml、启动服务、EPG/直连验证'
  fi
  echo
}

log() { printf '\n==> %s\n' "$*"; }
ok()  { printf '    %s\n' "$*"; }

# ------------------------------------------------------------- 参数就绪 -----
if [ -z "$ANSWERS" ]; then
  if is_tty; then
    wizard_make_answers
  else
    echo '非交互运行必须提供 --answers <file>。' >&2
    exit 1
  fi
fi
[ -f "$ANSWERS" ] || { echo "找不到 answers 文件：$ANSWERS" >&2; exit 1; }

# root 密码可从 answers（ROOT_PASSWORD=）读取，命令行/向导优先
if [ -z "$ROOT_PASSWORD" ]; then
  ROOT_PASSWORD=$( ( set +u; . "$ANSWERS" >/dev/null 2>&1; printf '%s' "${ROOT_PASSWORD:-}" ) )
fi

BOOTSTRAP=${BOOTSTRAP:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/install-dhcp.sh}
[ -f "$BOOTSTRAP" ] || { echo "找不到 bootstrap：$BOOTSTRAP" >&2; exit 1; }

PKG_TMP=''
if [ -z "$PKG_DIR" ] && [ -d "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/app/bin" ] \
   && [ -f "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/app/systemd/iptv-spider.service" ]; then
  SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  PKG_TMP=$(mktemp -d /tmp/iptv-pve-pkg.XXXXXX)
  cp -a "$SCRIPT_DIR/app/." "$PKG_TMP/"
  cp "$BOOTSTRAP" "$PKG_TMP/install-dhcp.sh"
  PKG_DIR=$PKG_TMP
  ok "自包含模式：使用本仓库 app/ 作为发行包（$SCRIPT_DIR/app）"
fi

if [ -n "$PKG_DIR" ]; then
  [ -d "$PKG_DIR/bin" ] && [ -f "$PKG_DIR/systemd/iptv-spider.service" ] || { echo "--pkg-dir 不是完整发行目录：$PKG_DIR" >&2; exit 1; }
fi

# MAC/DUID 一致性：answers 中 DHCP_DUID 非空时必须有 --eth1-mac
# 注意：必须判"值非空"，不能只看 `^DHCP_DUID=` 是否出现——answers 模板里本来就有一行空的
# DHCP_DUID=（照文档复制模板填写就会命中），旧写法会误报。
DUID_IN_ANSWERS=$( ( set +u; . "$ANSWERS" >/dev/null 2>&1; printf '%s' "${DHCP_DUID:-}" ) )
if [ -n "$DUID_IN_ANSWERS" ] && [ -z "$ETH1_MAC" ]; then
  echo 'answers 中设置了 DHCP_DUID（续用原租约），必须同时指定 --eth1-mac 保持一致。' >&2
  exit 1
fi

resolve_vmid
resolve_mgmt_ip

# 随机 PVE 风格 MAC（BC:24:11 前缀），或使用用户指定值
if [ -z "$ETH1_MAC" ]; then
  ETH1_MAC=$(printf 'BC:24:11:%02X:%02X:%02X' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))
  ok "未指定 --eth1-mac，随机生成：$ETH1_MAC（续租约需固定 MAC + DUID）"
fi

if [ -z "$TEMPLATE" ]; then
  TEMPLATE=$(for tdir in /var/lib/vz/template/cache /mnt/pve/*/template/cache; do [ -d "$tdir" ] && find "$tdir" -maxdepth 1 -type f -name 'debian-12-standard*.tar.zst' -printf '%f\n' 2>/dev/null || true; done | head -n1)
  [ -n "$TEMPLATE" ] || { echo '未找到 Debian 12 模板，请用 --template 指定。' >&2; exit 1; }
  TEMPLATE="local:vztmpl/$TEMPLATE"
fi

# ------------------------------------------------------------ bridge 持久化 ---
persist_bridge() {
  local conf=/etc/network/interfaces.d/50-iptv-vlan${IPTV_VLAN}.conf
  if grep -rqs "$IPTV_BRIDGE" /etc/network/interfaces /etc/network/interfaces.d/ 2>/dev/null; then
    ok "桥 $IPTV_BRIDGE 已在网络配置中持久化（跳过写入）"
    return 0
  fi
  install -d -m 0755 /etc/network/interfaces.d
  cat > "$conf" <<EOF
auto ${IPTV_UPLINK}.${IPTV_VLAN}
iface ${IPTV_UPLINK}.${IPTV_VLAN} inet manual
    vlan-raw-device ${IPTV_UPLINK}

auto ${IPTV_BRIDGE}
iface ${IPTV_BRIDGE} inet manual
    bridge-ports ${IPTV_UPLINK}.${IPTV_VLAN}
    bridge-stp off
    bridge-fd 0
EOF
  ok "已持久化到 $conf（重启 PVE 后自动生效）"
  log '提示：未执行 ifreload -a，避免中断线上 CT；若为全新 PVE 请重启或手工 ifreload -a。'
}

ensure_runtime_bridge() {
  [ "$APPLY_LIVE" -eq 1 ] || return 0
  if ip link show "$IPTV_BRIDGE" >/dev/null 2>&1; then
    ok "运行态桥 $IPTV_BRIDGE 已存在"
    return 0
  fi
  log "运行态补建桥 $IPTV_BRIDGE（uplink=$IPTV_UPLINK vlan=$IPTV_VLAN）"
  modprobe 8021q 2>/dev/null || true
  ip link add link "$IPTV_UPLINK" name "${IPTV_UPLINK}.${IPTV_VLAN}" type vlan id "$IPTV_VLAN"
  ip link add name "$IPTV_BRIDGE" type bridge
  ip link set "${IPTV_UPLINK}.${IPTV_VLAN}" master "$IPTV_BRIDGE"
  ip link set "${IPTV_UPLINK}.${IPTV_VLAN}" up
  ip link set "$IPTV_BRIDGE" up
  ok '运行态桥已补建并启用'
}

# --------------------------------------------------------------- CT 创建 -----
if pct config "$VMID" >/dev/null 2>&1; then
  if [ "$DESTROY_EXISTING" -eq 1 ]; then
    log "销毁现有容器 $VMID（--destroy-existing）"
    pct stop "$VMID" >/dev/null 2>&1 || true
    pct destroy "$VMID"
  fi
fi

persist_bridge
ensure_runtime_bridge

log "创建容器 $VMID（$HOSTNAME）"
ok "eth0 管理网：$MGMT_IP/24 via $MGMT_GW（$MGMT_BRIDGE）"
ok "eth1 IPTV：bridge=$IPTV_BRIDGE hwaddr=$ETH1_MAC（不带 ip=，DHCP 由 CT 自取）"
ok "模板：$TEMPLATE  存储：$STORAGE  内存：${MEM}MB  磁盘：${DISK}G"
pct create "$VMID" "$TEMPLATE" \
  --arch amd64 --cores "$CORES" --memory "$MEM" --swap 512 \
  --hostname "$HOSTNAME" \
  --rootfs "${STORAGE}:${DISK}" \
  --unprivileged 1 --features nesting=1 --onboot 1 \
  --net0 "name=eth0,bridge=${MGMT_BRIDGE},gw=${MGMT_GW},ip=${MGMT_IP}/24,type=veth" \
  --net1 "name=eth1,bridge=${IPTV_BRIDGE},hwaddr=${ETH1_MAC},type=veth"
pct set "$VMID" --description 'IPTV Spider DHCP-direct node created by pve-iptv-dhcp-create.sh'
pct start "$VMID"

log '等待容器启动'
ready=0
for i in $(seq 1 60); do
  if pct exec "$VMID" -- true >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[ "$ready" -eq 1 ] || { echo "容器 $VMID 60 秒内未就绪。" >&2; exit 1; }

# SSH root 可用（模板一般已带 openssh-server；缺失则安装）
pct exec "$VMID" -- sh -c 'command -v sshd >/dev/null 2>&1 || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y --no-install-recommends openssh-server; }' >/dev/null
if [ -n "$SSH_PUBKEY" ] && [ -f "$SSH_PUBKEY" ]; then
  pct push "$VMID" "$SSH_PUBKEY" /tmp/iptv-key.pub >/dev/null
  pct exec "$VMID" -- sh -c 'mkdir -p /root/.ssh && chmod 700 /root/.ssh && grep -qxF "$(cat /tmp/iptv-key.pub)" /root/.ssh/authorized_keys 2>/dev/null || cat /tmp/iptv-key.pub >> /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys 2>/dev/null; rm -f /tmp/iptv-key.pub'
  ok "已注入 SSH 公钥：$SSH_PUBKEY"
fi

# 允许 SSH root 登录；设置了 root 密码则一并写入容器（密码登录）
set_root_login() {
  pct exec "$VMID" -- sh -c 'install -d -m 0755 /etc/ssh/sshd_config.d 2>/dev/null || mkdir -p /etc/ssh/sshd_config.d; printf "PermitRootLogin yes\nPasswordAuthentication yes\n" > /etc/ssh/sshd_config.d/99-iptv-root.conf; systemctl try-restart sshd >/dev/null 2>&1 || service ssh restart >/dev/null 2>&1 || true'
  if [ -n "$ROOT_PASSWORD" ]; then
    printf '%s\n' "root:$ROOT_PASSWORD" | pct exec "$VMID" -- chpasswd
    ok '已设置 root 密码并允许 SSH root 登录（密码/公钥均可）'
  else
    ok '已允许 SSH root 登录（公钥方式；未设置密码）'
  fi
}
set_root_login

# STB_MODE=capture + 私钥登录：把本机 RouterOS SSH 私钥推送到容器内供抓包使用
push_routeros_key() {
  local stb_mode auth key
  stb_mode=$(sed -n 's/^STB_MODE=\(.*\)$/\1/p' "$ANSWERS" | tail -n1 | tr -d "'\"")
  [ "$stb_mode" = capture ] || return 0
  auth=$(sed -n 's/^ROUTER_AUTH=\(.*\)$/\1/p' "$ANSWERS" | tail -n1 | tr -d "'\"")
  [ "$auth" = key ] || return 0
  key=${ROUTER_KEY_PVE:-}
  if [ -z "$key" ] || [ ! -f "$key" ]; then
    ok '提示：抓包采用 RouterOS 私钥登录，但未找到可推送的本机私钥（--routeros-key）；请在容器内准备好 ROUTER_KEY。'
    return 0
  fi
  pct exec "$VMID" -- sh -c 'mkdir -p /root/.ssh && chmod 700 /root/.ssh'
  pct push "$VMID" "$key" /root/.ssh/id_ed25519_routeros >/dev/null 2>&1 || { echo '推送 RouterOS 私钥到容器失败。' >&2; exit 1; }
  pct exec "$VMID" -- sh -c 'chmod 600 /root/.ssh/id_ed25519_routeros'
  ok "已推送 RouterOS SSH 私钥到容器：$key -> /root/.ssh/id_ed25519_routeros"
}
push_routeros_key

# 上传 answers 与 bootstrap
work=$(mktemp -d /tmp/iptv-dhcp-work.XXXXXX)
trap 'rm -rf "$work" "$PKG_TMP"; [ -n "${ANSWERS_TMP:-}" ] && rm -f "$ANSWERS_TMP"' EXIT
if [ -n "${ANSWERS_TMP:-}" ]; then
  cp "$ANSWERS_TMP" /root/install-dhcp.conf
  chmod 600 /root/install-dhcp.conf
  ANSWERS=/root/install-dhcp.conf
fi
cp "$ANSWERS" "$work/install-dhcp.conf"
chmod 600 "$work/install-dhcp.conf"
pct push "$VMID" "$work/install-dhcp.conf" /root/install-dhcp.conf >/dev/null

if [ -n "$PKG_DIR" ]; then
  log "上传本地发行包 $PKG_DIR 到容器"
  pct exec "$VMID" -- sh -c 'rm -rf /root/iptv-pkg && mkdir -p /root/iptv-pkg'
  tar -C "$PKG_DIR" --exclude='.git' -cf - . | pct exec "$VMID" -- sh -c 'tar -C /root/iptv-pkg -xf -'
  pct exec "$VMID" -- bash /root/iptv-pkg/install-dhcp.sh /root/install-dhcp.conf
else
  pct push "$VMID" "$BOOTSTRAP" /root/install-dhcp.sh >/dev/null
  pct exec "$VMID" -- bash /root/install-dhcp.sh /root/install-dhcp.conf
fi

echo
log "完成：容器 $VMID（$HOSTNAME，$MGMT_IP）"
pct exec "$VMID" -- ip -4 -o addr show eth1 | sed 's/^/  /'
echo "  TiviMate：http://$MGMT_IP:8888/tv.m3u"
echo "  IPTV#：http://$MGMT_IP:8888/iptvsharp.m3u"
echo '常用命令：pct exec '$VMID' -- bash  或  ssh root@'$MGMT_IP
