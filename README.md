# iptv-spider-pve

上海电信 IPTV Spider 的 **PVE/CT 网络与安装编排**：在 Proxmox VE 上把一个全新
Debian 12 CT 一键装成"DHCP-direct"的 IPTV Spider 节点（eth1 在 VLAN85 专网自行
获取 DHCP 租约，专网路由与源 IP 随租约自动维护，无需 RouterOS SNAT/静态路由）。

应用本体（iptv-spider）与账号参数不在本仓库：运行时按需从
`driftbottle61/sh-iptv-manager` 的 GitHub Release 拉取，或使用本地发行目录
`--pkg-dir`。

## 架构

- `install.sh`：一键引导。下载同版本源码包后透传参数给编排脚本。
- `pve-iptv-dhcp-create.sh`：PVE 编排（root 运行）。
  - 持久化 IPTV VLAN 桥（写 `/etc/network/interfaces.d/50-iptv-vlanNN.conf`，
    全新 PVE 重启后生效；加 `--apply-live` 可立即补建运行态桥）
  - `pct create` 全新 CT：eth0=管理网静态、eth1=IPTV 桥（不带 `ip=`）
  - 注入 SSH 公钥、上传参数文件与发行包，最后在 CT 内执行 `install-dhcp.sh`
- `install-dhcp.sh`：CT 内非交互引导（root 运行）。
  - eth1 改 `iface eth1 inet dhcp`（标记段 `# BEGIN IPTV-SPIDER DHCP`）
  - 写入 dhclient hooks：拦默认路由/DNS 改写；按"租约网关"维护
    `218.83/222.68/124.75` 三条专网路由，`config.yaml` 的 `stb.ip` 变化时自动
    重启服务
  - 可选预置 DUID（配合 veth 固定 MAC 可续用原租约 IP）
  - 安装应用发行包、本机 MariaDB、生成 `config.yaml`、启动服务并验证
    认证/EPG 直连

## 快速开始（一条命令）

前置：Proxmox VE root Shell；本机已有 Debian 12 CT 模板
（`local:vztmpl/debian-12-standard_*.tar.zst`）；RouterOS 侧已存在 VLAN85 二层
路径（`lan-vlan85`+`pon-vlan85` 在同一 bridge，或等价拓扑）。

1. 准备参数文件（含 IPTV 账号凭据，勿提交 Git）：

```bash
curl -fsSL https://raw.githubusercontent.com/driftbottle61/iptv-spider-pve/v0.1.0/install-dhcp.conf.example \
  -o /root/install-dhcp.conf
vi /root/install-dhcp.conf   # 填写 LAN_IP / STB_UID / STB_MAC / STB_SN / STB_TYPE / MYSQL_PASSWORD 等
chmod 600 /root/install-dhcp.conf
```

2. 一键安装（会创建全新 CT 并完成全部配置）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/driftbottle61/iptv-spider-pve/v0.1.0/install.sh) \
  --answers /root/install-dhcp.conf \
  --vmid 118 --hostname iptv-spider \
  --mgmt-ip 192.168.100.93 --mgmt-gw 192.168.100.1 \
  --ssh-pubkey /root/.ssh/id_ed25519.pub
```

安装完成后用 `pct reboot <vmid>` 重启一次，确认 eth1 租约、专网路由与
iptv-spider/mariadb 服务自动恢复。

## 参数表（pve-iptv-dhcp-create.sh）

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `--answers <file>` | 必填 | CT 安装参数文件（shell `KEY=value`） |
| `--vmid <n>` | `114` | 容器 ID（须未被 CT/VM 占用） |
| `--hostname` | `iptv-spider` | 容器主机名 |
| `--mgmt-bridge` | `vmbr0` | 管理网桥 |
| `--mgmt-ip` | answers 的 `LAN_IP` | 管理网 IP |
| `--mgmt-gw` | `192.168.100.1` | 管理网网关 |
| `--iptv-bridge` | `vmbr0v85` | IPTV 桥（脚本负责持久化） |
| `--iptv-uplink` | `nic1` | IPTV 桥的上联物理网卡 |
| `--iptv-vlan` | `85` | IPTV VLAN |
| `--eth1-mac` | 随机生成 | veth 固定 MAC；与 answers 的 `DHCP_DUID` 必须成对 |
| `--template` | 自动查找 | Debian 12 CT 模板 |
| `--storage` | `local-lvm` | CT 根目录存储 |
| `--mem/--disk/--cores` | `2048/16/2` | 容器资源 |
| `--ssh-pubkey <file>` | 无 | 注入 CT root 的 SSH 公钥 |
| `--pkg-dir <dir>` | 无 | sh-iptv-manager 发行目录（缺省则 CT 内走 GitHub Release） |
| `--destroy-existing` | 关 | 同 vmid 已存在时先停止并销毁（危险） |
| `--apply-live` | 关 | IPTV 桥不存在时立即补建运行态桥 |

## 分步手工安装（调试用）

```bash
# PVE：创建容器
pct create 118 local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --arch amd64 --cores 2 --memory 2048 --swap 512 --hostname iptv-spider \
  --rootfs local-lvm:16 --unprivileged 1 --features nesting=1 --onboot 1 \
  --net0 name=eth0,bridge=vmbr0,gw=192.168.100.1,ip=192.168.100.93/24,type=veth \
  --net1 name=eth1,bridge=vmbr0v85,type=veth
pct start 118

# PVE：上传参数文件与 CT 引导脚本
pct push 118 /root/install-dhcp.conf /root/install-dhcp.conf
pct push 118 /root/scripts/iptv-spider-pve/install-dhcp.sh /root/install-dhcp.sh

# CT 内执行引导
pct exec 118 -- bash /root/install-dhcp.sh /root/install-dhcp.conf
```

## 验证清单

```bash
pct exec 118 -- sh -c '
  ip -4 -o addr show eth1
  ip route show | grep eth1
  systemctl is-active iptv-spider mariadb
  grep "^  ip:" /opt/sh-iptv-spider/config.yaml
  MYSQL_PWD=<db密码> mariadb -N -h127.0.0.1 -uiptv iptv -e "SELECT COUNT(*) FROM epg_details;"
  timeout 6 bash -c "</dev/tcp/222.68.208.73/7001" && echo AUTH-OPEN
'
```

## 常见问题

- **全新 PVE 重启后 IPTV 桥没起来**：脚本只写了持久化配置，未执行
  `ifreload -a`（避免中断线上 CT）；全新 PVE 需重启，或手工 `ifreload -a`。
- **想续用原租约 IP**：`--eth1-mac` 与 answers 的 `DHCP_DUID` 成对指定即可；
  两者来自旧机 `/var/lib/dhcp/dhclient.eth1.leases` 的 `default-duid` 与 veth MAC。
- **apt 很慢**：CT 首次安装 MariaDB 需从 Debian 官方源下载，耐心等待即可。
