# 上海电信 IPTV Spider 安装包

该安装包用于合法订阅的上海电信 IPTV 用户，提供频道抓取、XMLTV、直播 M3U、TVOD 回看和本地 Logo 服务。安装包不含任何 IPTV 账号、机顶盒认证信息或数据库数据。

## 安装时获取机顶盒参数

安装程序提供两种方式：手工填写，或通过 RouterOS 自动抓取实体机顶盒认证信息。
自动抓包适用于新建 Ubuntu/CT 尚未接入 IPTV 专网的情况，安装主机只需能通过 SSH
访问 RouterOS。发行包已包含 `stb-probe`，无需安装 Go。

选择自动抓包后，安装程序会询问 RouterOS 地址、SSH 端口、用户名、登录方式、连接
机顶盒的物理端口和抓包时长。登录方式支持用户名和密码，也支持 SSH 私钥；密码采用
隐藏输入，只通过临时进程环境传给 `sshpass`，不会写入 `config.yaml` 或日志。按提示
准备好后按回车，看到“现在重启机顶盒”时立即
重新启动实体机顶盒。抓包结束后会完整显示 UID、MAC、SN、型号、认证服务器、A 面
IP、B 面 IP 和 B 面网关，并自动写入 `config.yaml`。
认证服务器地址由程序固定为 `222.68.208.73:7001`，不会采用抓包中出现的其他
TM 或后端 7001 地址。

其余组件安装完成后，程序会提示关闭实体机顶盒。用户输入 `YES` 确认后，安装程序
把抓到的 B 面专网 IP 持久化到 `eth1`，仅启用该接口并重启 IPTV Spider，不会重启
整个网络服务，也不会修改承载 SSH 的 `eth0`。如暂时不希望接管机顶盒专网地址，可
输入 `SKIP`，以后再手工配置。

抓包期间工具会临时关闭指定 RouterOS bridge port 的硬件卸载，并在结束后恢复；也会
保存和恢复 RouterOS 全局 sniffer 参数、删除临时 pcap。默认物理端口为
`ether3_lan`，默认不限制 VLAN，因此可以同时识别未打标签流量、VLAN 51 和 VLAN 85。
机顶盒认证参数属于账号凭据，请勿公开发布。

## 在 Proxmox VE 创建 CT

推荐使用 Debian 12 非特权 CT。下面的模板以 CT 编号 `116`、管理地址
`192.168.100.90/24`、网关 `192.168.100.1` 和存储 `local-lvm` 为例：

```bash
pct create 116 local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --arch amd64 \
  --cores 2 \
  --memory 2048 \
  --swap 512 \
  --hostname iptv-spider \
  --rootfs local-lvm:10 \
  --unprivileged 1 \
  --features nesting=1 \
  --onboot 1 \
  --net0 name=eth0,bridge=vmbr0,gw=192.168.100.1,ip=192.168.100.90/24,type=veth \
  --net1 name=eth1,bridge=vmbr0,tag=85,type=veth \
  --net2 name=eth2,bridge=vmbr0,tag=51,type=veth
```

执行前先确认 CT 编号未被占用，并检查模板文件名：

```bash
pct status 116
pveam list local | grep debian-12
```

如果本机模板名称不同，请替换 `local:vztmpl/...`；如果使用其他存储，请同时替换
`local-lvm:10`。`vmbr0` 及其上联交换链路必须允许所需 VLAN 通过。

三张网卡的用途如下：

- `eth0`：LAN 管理网卡，固定地址为 `192.168.100.90/24`，安装、SSH、M3U、EPG 和 Logo 服务均通过它访问。
- `eth1`：VLAN 85 IPTV 专网网卡。创建时无需填写 IP；自动抓包安装流程会在最后提示关闭实体机顶盒，并把抓到的 B 面专网 IP 配置到该接口。
- `eth2`：VLAN 51 预留网卡，用于需要 A 面或特定认证网络的环境。当前 IPTV Spider 的常规安装和运行不依赖它；确定不用时可以省略 `--net2`。

创建后启动、进入和查看配置：

```bash
pct start 116
pct enter 116
pct config 116
```

进入 CT 后确认 `eth0` 能访问 LAN 和互联网，再运行一键安装程序。不要在 PVE
宿主机或 CT 内同时给 `eth1` 配置与仍在线机顶盒相同的专网 IP，以免发生地址冲突。

## 安装

在 Debian 12、Ubuntu 22.04 或更新版本的服务器上解压发行包后执行：

```bash
chmod +x install.sh
sudo ./install.sh
```

安装程序会交互式询问两类参数：

- 抓取模块：可手工填写，或通过 RouterOS 抓包自动取得 IPTV UID、机顶盒 MAC、SN、A/B 面 IP、型号、网关和认证服务器。
- 回放模块：已有直播 M3U 源、udpxy/msd_lite 地址、回看天数和需要由本服务中继回看流的客户端 IP。

安装脚本会安装 MariaDB，若数据库地址填写 `127.0.0.1` 或 `localhost`，会自动创建数据库和用户。生成的 `config.yaml` 权限为 `600`，请勿提交到 Git 或公开分享。

服务启动后，安装程序会等待首次 EPG 抓取（最多 3 分钟），并显示频道记录数、已有
节目单频道数、节目总数、节目覆盖时间及抓取警告数。如果超时或服务启动失败，会显示
对应的日志检查命令，但不会删除已经生成的配置。

## 地址

安装完成后会显示实际地址。常用接口：

```text
http://<server>:<port>/tv.m3u
http://<server>:<port>/iptvsharp.m3u
http://<server>:<port>/api/epg?daysAgo=7
http://<server>:<port>/iptvlogos/CGTN.png
```

`tv.m3u` 为 TiviMate 播放列表、`iptvsharp.m3u` 为 IPTV# 播放列表，两者内容一致，
仅在回看时间参数的写法上按客户端区分；均使用配置的 udpxy/msd_lite 把 IPTV 多播
转换为 HTTP 单播，并附加 TVOD 回看属性。若实际 udpxy/msd_lite 地址不是内置默认
`192.168.100.51:4022`，可在链接后追加 `?udpxy=<地址:端口>`。Logo 与频道分组来自
安装包中的离线参考映射，不依赖外部 Logo 主机。

## 服务管理

使用中文日常管理菜单：

```bash
iptv-spider
```

菜单提供状态显示、手动抓取频道和 EPG、重启服务以及交互式卸载。选择 `0` 只退出
菜单，不会停止 IPTV Spider 服务。

```bash
systemctl status iptv-spider
journalctl -u iptv-spider -f
systemctl restart iptv-spider
```

配置文件位于安装目录下的 `config.yaml`。修改后重启服务即可生效。

日常检查可以执行：

```bash
iptv-spider-status
```

该命令会显示软件版本、systemd 状态、监听端口、`eth1` 专网地址、M3U/EPG/Logo
接口状态、数据库频道与节目数量、EPG 覆盖时间、最近两小时的错误日志，并动态选择
一个已经播完的节目进行 5 秒回放取流测试。只查看状态、不测试回放时执行：

```bash
iptv-spider-status --skip-replay
```

全新安装和覆盖升级成功后，安装器也会自动执行一次完整状态检查。

## 覆盖升级

在已经安装 IPTV Spider 的服务器上运行新版一键安装命令，安装器检测到现有
`config.yaml` 后会提供覆盖升级选项。覆盖升级会：

- 保留现有 `config.yaml`、数据库内容和 `eth1` 的安装器配置段；覆盖后按新抓包结果重写 IPTV 地址与路由；
- 更新主程序、抓包工具、Logo、频道映射、帮助文件和 systemd 单元；
- 在安装目录旁创建带时间戳的完整备份；
- 新版本无法稳定启动时自动恢复旧版本。

覆盖升级必须重新通过 RouterOS 抓取机顶盒信息，但不会要求重新输入数据库密码。抓包成功后，
可手工删除安装目录旁的 `upgrade-backup` 备份。

## 卸载

安装完成后可以执行：

```bash
iptv-spider-uninstall
```

卸载程序默认只停止并删除 IPTV Spider 服务和程序，保留配置、日志、数据库及
MariaDB 软件包。交互过程中可以单独选择是否删除 IPTV 数据库和用户、是否卸载
MariaDB。若网络配置中存在安装器创建的 `IPTV-SPIDER ETH1` 标记段，卸载时只移除
该段且不会重启网络。选择保留配置时，文件会备份到 `/root/iptv-spider-uninstall-backup-*`。

## RouterOS 回看路由

回看调度和视频 CDN 必须经 IPTV 专网网关访问。以下以 `30.182.0.1` 为例，实际网关
应使用抓包得到的 B 面网关：

```routeros
/ip route
add dst-address=222.68.211.94/32 gateway=30.182.0.1 comment="IPTV TVOD dispatch"
add dst-address=124.75.26.0/24 gateway=30.182.0.1 comment="IPTV TVOD CDN"
add dst-address=124.75.27.0/24 gateway=30.182.0.1 comment="IPTV TVOD CDN"
add dst-address=124.75.28.0/24 gateway=30.182.0.1 comment="IPTV TVOD CDN"
```

特别是 `124.75.26.0/24`：缺少这条路由时，部分节目会先报 401/404 或长时间加载，
重试后才可能播放。安装程序不会自动修改 RouterOS 路由。

## 更新

升级前备份当前配置：

```bash
cp /opt/sh-iptv-spider/config.yaml /root/iptv-spider-config.yaml.bak
```

新发行包默认不会覆盖已有 `config.yaml`；需要先确认并迁移新增配置字段后再升级。

覆盖安装时也必须重新通过 RouterOS 抓取实体机顶盒。抓包成功后，安装程序只更新
`config.yaml` 中的 UID、MAC、SN、型号、A/B 面地址和认证地址，保留数据库、服务端口、
直播源、回放设置及其他配置；原机顶盒配置会单独备份。安装程序还会重新写入 `eth1`
的静态 `/16` 地址，并输出当前三层出口所需的 RouterOS 路由、转发和 SNAT 命令。
CT 不直接把机顶盒 B 面网关作为二层邻居，而是以 RouterOS 的 IPTV DHCP 地址作为
`eth1` 路由下一跳；RouterOS 再经 `bridge_iptv` 转发到抓包得到的 B 面网关，并将
CT 源地址 SNAT 为该 IPTV DHCP 地址。安装时会询问当前 `bridge_iptv` DHCP 地址，
并把实际地址写入 Linux 持久化路由及 RouterOS 命令输出。

## PVE Shell 前置准备脚本

在 Proxmox VE 主机 Shell 以 root 运行：

```bash
./pve-iptv-prep.sh
```

脚本提供两个菜单：

1. RouterOS：输入地址、SSH 端口、用户名、密码、IPTV 上联端口、PVE/机顶盒接入口、VLAN ID 和 Option 125，生成并在确认后执行 RouterOS 配置。
2. CT：自动寻找 Debian 12 CT 模板；没有模板时使用 `pveam` 下载，选择未占用 CT ID 和未响应的 `30.181.165.0/24` 地址，创建接入 IPTV Bridge 的 Debian 12 CT。

RouterOS 的 VLAN ID、上联端口、Bridge 端口和 Option 125 内容与运营商线路及现有配置强相关。首次使用建议选择不执行，仅审阅脚本打印的 RouterOS 命令；Option 125 还必须按现场 DHCP Server 结构绑定到对应网络。脚本不会自动删除已有 Bridge、VLAN、DHCP 或 IGMP 配置。

前置准备脚本会在继续操作前强制抓取一次实体机顶盒流量：

- 菜单 1 先从抓包结果识别 802.1Q VLAN 和 DHCP Option 125，再把识别值带入 RouterOS 配置预览。
- 菜单 2 不抓包，只扫描 RouterOS 当前 Bridge、端口、VLAN、DHCP Client、Option 125 和 IGMP Proxy；扫描完成后才允许创建 CT。
- 机顶盒抓包仅用于菜单 1 识别 VLAN/Option 125，或 CT 创建后由 `iptv-spider` 安装程序获取认证参数。

### RouterOS IPTV DHCP 地址自动同步

安装时若选择配置 RouterOS SSH 公钥，安装器会自动读取 `bridge_iptv` 的 DHCP 租约，并安装 `iptv-routeros-sync.timer` 每分钟检查一次。租约变化后会同步：

- CT `eth1` 的 EPG/认证专网路由；
- `/etc/network/interfaces` 中 IPTV 路由的持久化下一跳；
- RouterOS 中带有 `iptv-spider CT ... SNAT` 注释的 NAT 规则。

查看状态和日志：

```bash
systemctl status iptv-routeros-sync.timer
journalctl -u iptv-routeros-sync.service -n 50 --no-pager
```

自动同步不保存 RouterOS 明文密码，建议先配置仅允许 RouterOS 管理 SSH 登录的密钥。若安装时跳过密钥，仍可手工配置 `/etc/iptv-spider/routeros-sync.conf` 后启用该 timer。

## DHCP-direct 一键安装（iptv-spider-pve：install.sh + pve-iptv-dhcp-create.sh + app/，v0.3.0+）

面向"全新 Debian 12 CT 一键变成 IPTV Spider 节点"的自动安装路径，与上面
install.sh 的"静态 B 面 IP + RouterOS 中转"架构不同，本路径让 CT 自己在
VLAN85 专网上获取 DHCP 租约，网关与源 IP 全部随租约自动维护，不依赖
RouterOS SNAT/静态路由（2026-09-08 已在测试 CT 上删机重建验证，含重启恢复）。

两个脚本：

- `install-dhcp.sh`：CT 内非交互引导（root 运行）。参数文件为 shell 格式
  `KEY=value`（见 `install-dhcp.conf.example`）。完成：eth1 改 `inet dhcp`、
  写入 dhclient hooks（拦默认路由/DNS 改写 + 按租约网关维护 IPTV 专网路由 +
  `config.yaml` 的 `stb.ip` 变化自动重启服务）、可选 DUID 预置（配合 PVE
  veth 固定 MAC 可续用原租约 IP）、安装应用发行包（本地目录或 GitHub
  Release）、本机 MariaDB、生成 `config.yaml`、启动服务并验证认证/EPG 直连。
- `pve-iptv-dhcp-create.sh`：PVE 编排（root 运行）。持久化 IPTV VLAN 桥
  （写 `/etc/network/interfaces.d/50-iptv-vlanNN.conf`）、`pct create` 创建
  全新 CT（eth0=管理网静态、eth1=IPTV 桥不带 `ip=`、固定 MAC）、注入 SSH
  公钥、上传发行包与参数文件，最后在 CT 内执行 `install-dhcp.sh`。

示例（PVE Shell）：

```bash
./pve-iptv-dhcp-create.sh \
  --answers /root/install-dhcp.conf \
  --vmid 114 --hostname iptv-spider \
  --mgmt-ip 192.168.100.92 --mgmt-gw 192.168.100.1 \
  --eth1-mac BC:24:11:87:B7:32 \
  --pkg-dir /root/app \
  --ssh-pubkey /root/.ssh/id_ed25519.pub \
  --destroy-existing
```

要点：

- 参数文件含 IPTV 账号凭据，建议 `chmod 600` 且不要提交 Git。
- 想续用原租约 IP：`--eth1-mac` 与参数文件 `DHCP_DUID` 必须成对一致。
- 全新 PVE：脚本写桥持久化后需重启 PVE（或手工 `ifreload -a`）才生效；
  若桥尚不存在可加 `--apply-live` 立即补建运行态桥。
- 现有容器替换：加 `--destroy-existing`（危险，会先停止并销毁同 vmid 容器）。
- 专网直连要求 RouterOS 侧已有 VLAN85 二层路径（本仓库 `pve-iptv-prep.sh`
  菜单 1 可生成对应 RouterOS 配置）；CT 直连后 RouterOS 无需为该 CT 添加
  NAT/SNAT。
