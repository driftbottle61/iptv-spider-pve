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
  - **交互向导**（无参数运行）：自动扫描空闲 CT 号/管理 IP 作默认值，回车采用
    或手工输入；CT 号或 IP 冲突（被 CT/VM 占用、ping 通、邻居表存在）会提示后
    重新输入。随后引导选择机顶盒参数获取方式。
  - 持久化 IPTV VLAN 桥（写 `/etc/network/interfaces.d/50-iptv-vlanNN.conf`，
    全新 PVE 重启后生效；加 `--apply-live` 可立即补建运行态桥）
  - `pct create` 全新 CT：eth0=管理网静态、eth1=IPTV 桥（不带 `ip=`）
  - 注入 SSH 公钥、推送 RouterOS 抓包私钥（可选）、上传参数文件与发行包，
    最后在 CT 内执行 `install-dhcp.sh`
- `install-dhcp.sh`：CT 内引导（root 运行）。
  - eth1 改 `iface eth1 inet dhcp`（标记段 `# BEGIN IPTV-SPIDER DHCP`）
  - 写入 dhclient hooks：拦默认路由/DNS 改写；按"租约网关"维护
    `218.83/222.68/124.75` 三条专网路由，`config.yaml` 的 `stb.ip` 变化时自动
    重启服务
  - 可选预置 DUID（配合 veth 固定 MAC 可续用原租约 IP）
  - 机顶盒认证参数两种来源：
    - `STB_MODE=manual`：直接使用 answers 里的 `STB_UID/MAC/SN/...`
    - `STB_MODE=capture`：**RouterOS 抓包**——在实体机顶盒物理口上抓启动流量，
      自动提取 uid/mac/sn/type/auth_host/plane_* 填入 `config.yaml`；
      专网 IP 无需抓包，由 eth1 DHCP 租约提供。抓包需重启实体机顶盒，
      失败可交互降级为手工填写。
  - 安装应用发行包、本机 MariaDB、生成 `config.yaml`、启动服务并验证
    认证/EPG 直连

## 快速开始

前置：Proxmox VE root Shell；本机已有 Debian 12 CT 模板
（`local:vztmpl/debian-12-standard_*.tar.zst`）；RouterOS 侧已存在 VLAN85 二层
路径（`lan-vlan85`+`pon-vlan85` 在同一 bridge，或等价拓扑）；选择
`STB_MODE=capture` 时还需：实体机顶盒已接 RouterOS 物理口、可执行断电上电。

### A. 交互向导（推荐，全新安装）

直接在 PVE Shell 运行（**不要加任何参数**，本仓库在 PVE 上的本地副本即可）：

```bash
cd /root/scripts/iptv-spider-pve
./pve-iptv-dhcp-create.sh
```

交互过程：

1. **CT 号 / 管理网 IP**：自动扫描给出空闲建议值（如 `118` /
   `192.168.100.93`），回车采用，或手工输入；冲突会提示后重新输入。
2. **SSH root 登录**：默认允许 root 公钥登录；如需要密码登录，直接输入
   root 密码，创建后会一并写入容器并启用 SSH root 密码登录。
3. **机顶盒参数获取方式**：
   - `1) RouterOS 抓包（推荐）`：再填 RouterOS 地址/端口/用户名、登录方式
     （SSH 私钥或密码）、机顶盒物理口与抓包时长。私钥会自动推送到新 CT。
   - `2) 手工填写`：按提示输入 uid/mac/sn/type 等。
4. 确认直播/回放参数与本机 MariaDB 密码后自动开始创建 CT、配置网络。
5. 安装进行到抓包阶段时，**按提示断电→上电重启实体机顶盒**，等待抓包结束
   自动写入 `config.yaml`。

生成的参数会另存为 `/root/install-dhcp.conf` 供复用。

### B. 参数化 / 脚本化

准备参数文件（含 IPTV 账号凭据，勿提交 Git；`STB_MODE=capture` 时不需要填
`STB_*`，改为填 `ROUTER_*` 连接参数）：

```bash
curl -fsSL https://raw.githubusercontent.com/driftbottle61/iptv-spider-pve/v0.2.2/install-dhcp.conf.example \
  -o /root/install-dhcp.conf
vi /root/install-dhcp.conf
chmod 600 /root/install-dhcp.conf
```

一键安装（会创建全新 CT 并完成全部配置）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/driftbottle61/iptv-spider-pve/v0.2.2/install.sh) \
  --answers /root/install-dhcp.conf \
  --vmid 118 --hostname iptv-spider \
  --mgmt-ip 192.168.100.93 --mgmt-gw 192.168.100.1 \
  --ssh-pubkey /root/.ssh/id_ed25519.pub
```

`STB_MODE=capture` 的私钥登录方式可用 `--routeros-key /root/.ssh/<key>` 把
本机 RouterOS SSH 私钥自动推送到容器内（默认容器路径
`/root/.ssh/id_ed25519_routeros`）。

安装完成后用 `pct reboot <vmid>` 重启一次，确认 eth1 租约、专网路由与
iptv-spider/mariadb 服务自动恢复。

## 参数表（pve-iptv-dhcp-create.sh）

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| （无参数） | 交互向导 | 扫描空闲 CT/IP 建议值、冲突重输、机顶盒参数引导 |
| `--answers <file>` | 无 | CT 安装参数文件（shell `KEY=value`；与向导二选一） |
| `--vmid <n>` | 向导扫描 | 容器 ID（须未被 CT/VM 占用，冲突可重输） |
| `--hostname` | `iptv-spider` | 容器主机名 |
| `--mgmt-bridge` | `vmbr0` | 管理网桥 |
| `--mgmt-ip` | 向导扫描 | 管理网 IP（冲突提示重输；参数化时缺省取 answers 的 `LAN_IP`） |
| `--mgmt-gw` | `192.168.100.1` | 管理网网关 |
| `--iptv-bridge` | `vmbr0v85` | IPTV 桥（脚本负责持久化） |
| `--iptv-uplink` | `nic1` | IPTV 桥的上联物理网卡 |
| `--iptv-vlan` | `85` | IPTV VLAN |
| `--eth1-mac` | 随机生成 | veth 固定 MAC；与 answers 的 `DHCP_DUID` 必须成对 |
| `--template` | 自动查找 | Debian 12 CT 模板 |
| `--storage` | `local-lvm` | CT 根目录存储 |
| `--mem/--disk/--cores` | `2048/16/2` | 容器资源 |
| `--ssh-pubkey <file>` | 无 | 注入 CT root 的 SSH 公钥 |
| `--root-password <pw>` | 无 | 设置 CT root 密码并允许 SSH root 密码登录（也可在 answers 写 `ROOT_PASSWORD=`） |
| `--routeros-key <file>` | 无 | `STB_MODE=capture` 私钥登录时推送本机 RouterOS SSH 私钥到容器 |
| `--pkg-dir <dir>` | 无 | sh-iptv-manager 发行目录（缺省则 CT 内走 GitHub Release） |
| `--destroy-existing` | 关 | 同 vmid 已存在时先停止并销毁（危险） |
| `--apply-live` | 关 | IPTV 桥不存在时立即补建运行态桥 |

## answers 文件要点

见 `install-dhcp.conf.example`。核心字段：

- 通用：`LAN_IP / ETH1_IF / MYSQL_PASSWORD / UDPXY / CATCHUP_DAYS ...`
- CT root：`ROOT_PASSWORD`（可选；留空=SSH 仅公钥登录，设置后启用 root 密码登录）
- `STB_MODE=manual`：手工填 `STB_UID / STB_MAC / STB_SN / STB_TYPE ...`
- `STB_MODE=capture`：不需要 `STB_*`；填 `ROUTER_PRESET=1` 及
  `ROUTER_HOST / ROUTER_PORT / ROUTER_USER / ROUTER_AUTH / ROUTER_KEY`（或
  `ROUTER_PASSWORD`）/ `ROUTER_IFACE / CAPTURE_SECONDS`

## 验证清单

```bash
pct exec 118 -- sh -c '
  ip -4 -o addr show eth1
  ip route show | grep eth1
  systemctl is-active iptv-spider mariadb
  grep -A8 "^stb:" /opt/sh-iptv-spider/config.yaml
  MYSQL_PWD=<db密码> mariadb -N -h127.0.0.1 -uiptv iptv -e "SELECT COUNT(*) FROM epg_details;"
  timeout 6 bash -c "</dev/tcp/222.68.208.73/7001" && echo AUTH-OPEN
'
```

## 常见问题

- **全新 PVE 重启后 IPTV 桥没起来**：脚本只写了持久化配置，未执行
  `ifreload -a`（避免中断线上 CT）；全新 PVE 需重启，或手工 `ifreload -a`。
- **抓包没有识别到机顶盒**：确认 `ROUTER_IFACE` 是连实体机顶盒的物理口；
  抓包期间必须断电→上电重启机顶盒，并等它进到首页；可加长
  `CAPTURE_SECONDS` 后重试（脚本内输入 R）。
- **容器内没有 RouterOS 私钥**：`STB_MODE=capture` 用私钥登录时，先在本机用
  `--routeros-key`（向导会自动）把私钥推到容器
  `/root/.ssh/id_ed25519_routeros`；或改密码登录。
- **想用 root 密码 SSH 登录新 CT**：向导输入 root 密码，或参数化用
  `--root-password` / answers 的 `ROOT_PASSWORD=`；脚本写入
  `/etc/ssh/sshd_config.d/99-iptv-root.conf`（`PermitRootLogin yes`）并 `chpasswd`。
  生产建议仍以公钥登录为主。
- **想续用原租约 IP**：`--eth1-mac` 与 answers 的 `DHCP_DUID` 成对指定即可；
  两者来自旧机 `/var/lib/dhcp/dhclient.eth1.leases` 的 `default-duid` 与 veth MAC。
- **apt 很慢**：CT 首次安装 MariaDB 需从 Debian 官方源下载，耐心等待即可。
