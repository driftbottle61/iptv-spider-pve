#!/usr/bin/env bash
# pve-iptv-dhcp-create.sh - 一键创建全新 IPTV CT 并完成 DHCP-direct 安装
#
# 在 Proxmox VE 主机以 root 运行。流程：
#   0. 参数校验
#   1. PVE 侧：持久化 IPTV VLAN 桥（写 /etc/network/interfaces.d，可选运行态补建）
#   2. pct create 全新 Debian12 CT（eth0=管理网静态 / eth1=IPTV 桥、不带 ip=、固定 MAC）
#   3. 注入 SSH 公钥、上传发行包与参数文件
#   4. 在 CT 内执行 install-dhcp.sh（网络 + 应用 + 数据库 + 验证）
#
# 常用参数（均为可选，另有默认值）：
#   --answers <file>            必填：install-dhcp.sh 的 answers 文件（shell KEY=value）
#   --vmid 114                  容器 ID（默认 114）
#   --hostname iptv-spider
#   --mgmt-bridge vmbr0 --mgmt-gw 192.168.100.1
#   --mgmt-ip 192.168.100.92    管理网 IP（默认从 answers 的 LAN_IP 取）
#   --iptv-bridge vmbr0v85 --iptv-uplink nic1 --iptv-vlan 85
#   --eth1-mac BC:24:11:87:B7:32  固定 MAC；设置了 DHCP_DUID 时必须与之一致
#   --template local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst
#   --storage local-lvm --mem 2048 --disk 16 --cores 2
#   --ssh-pubkey <pubkey-file>  注入 CT root 的 SSH 公钥（可选）
#   --pkg-dir <dir>             本地发行包目录；不传则 CT 内走 GitHub Release
#   --bootstrap <install-dhcp.sh 路径>  默认与本脚本同目录
#   --destroy-existing          存在同 vmid 时先停止并销毁（危险，需显式指定）
#   --apply-live                桥不存在时执行运行态补建（一般只需持久化）
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo '请在 PVE Shell 以 root 运行。' >&2; exit 1; }
command -v pct >/dev/null 2>&1 || { echo '未检测到 pct，此脚本必须运行在 Proxmox VE 主机。' >&2; exit 1; }

ANSWERS=''
VMID=114
HOSTNAME=iptv-spider
MGMT_BRIDGE=vmbr0
MGMT_GW=192.168.100.1
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
PKG_DIR=''
DESTROY_EXISTING=0
APPLY_LIVE=0
BOOTSTRAP=''

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
    --pkg-dir) PKG_DIR=$2; shift 2 ;;
    --bootstrap) BOOTSTRAP=$2; shift 2 ;;
    --destroy-existing) DESTROY_EXISTING=1; shift ;;
    --apply-live) APPLY_LIVE=1; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done

[ -n "$ANSWERS" ] && [ -f "$ANSWERS" ] || { echo '缺少 --answers <file> 或文件不可读。' >&2; exit 1; }
BOOTSTRAP=${BOOTSTRAP:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/install-dhcp.sh}
[ -f "$BOOTSTRAP" ] || { echo "找不到 bootstrap：$BOOTSTRAP" >&2; exit 1; }

if [ -n "$PKG_DIR" ]; then
  [ -d "$PKG_DIR/bin" ] && [ -f "$PKG_DIR/systemd/iptv-spider.service" ] || { echo "--pkg-dir 不是完整发行目录：$PKG_DIR" >&2; exit 1; }
fi

# MAC/DUID 一致性：answers 中带 DHCP_DUID 时必须有 --eth1-mac
if grep -q '^DHCP_DUID=' "$ANSWERS" && [ -z "$ETH1_MAC" ]; then
  echo 'answers 中设置了 DHCP_DUID（续用原租约），必须同时指定 --eth1-mac 保持一致。' >&2
  exit 1
fi

# 管理网 IP 默认取 answers 的 LAN_IP
[ -n "$MGMT_IP" ] || MGMT_IP=$(sed -n 's/^LAN_IP=\(.*\)$/\1/p' "$ANSWERS" | tail -n1)
[ -n "$MGMT_IP" ] || { echo '未提供管理网 IP（--mgmt-ip 或 answers 的 LAN_IP）。' >&2; exit 1; }

valid_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local p
  IFS=. read -r -a p <<< "$1"
  for part in "${p[@]}"; do
    [ "$part" -ge 0 ] && [ "$part" -le 255 ] || return 1
  done
}
valid_ipv4 "$MGMT_IP" || { echo "管理网 IP 无效：$MGMT_IP" >&2; exit 1; }

# 随机 PVE 风格 MAC（BC:24:11 前缀），或使用用户指定值
if [ -z "$ETH1_MAC" ]; then
  ETH1_MAC=$(printf 'BC:24:11:%02X:%02X:%02X' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))
  echo "未指定 --eth1-mac，随机生成：$ETH1_MAC"
fi

if [ -z "$TEMPLATE" ]; then
  TEMPLATE=$(for tdir in /var/lib/vz/template/cache /mnt/pve/*/template/cache; do [ -d "$tdir" ] && find "$tdir" -maxdepth 1 -type f -name 'debian-12-standard*.tar.zst' -printf '%f\n' 2>/dev/null || true; done | head -n1)
  [ -n "$TEMPLATE" ] || { echo '未找到 Debian 12 模板，请用 --template 指定。' >&2; exit 1; }
  TEMPLATE="local:vztmpl/$TEMPLATE"
fi

log() { printf '\n==> %s\n' "$*"; }
ok()  { printf '    %s\n' "$*"; }

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
  else
    echo "容器 $VMID 已存在；如需替换请加 --destroy-existing。" >&2
    exit 1
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

# 上传 answers 与 bootstrap
work=$(mktemp -d /tmp/iptv-dhcp-work.XXXXXX)
trap 'rm -rf "$work"' EXIT
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
echo '常用命令：pct exec '$VMID' -- bash  或  ssh root@'$MGMT_IP
