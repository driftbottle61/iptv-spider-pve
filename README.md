# iptv-spider-pve

上海电信 IPTV Spider 的**单仓库自包含**版本：PVE/CT 编排脚本、应用本体（`app/`）
与编译产物都放在同一个仓库、同一次 Release 里。全新安装**不依赖任何其它 GitHub
仓库**（旧架构的 `sh-iptv-manager`、`iptv-spider-pro` 均已不再需要）。

在一个全新 Debian 12 CT 上把 PVE 侧一键装成 "DHCP-direct" 的 IPTV Spider 节点：
`eth1` 在 VLAN85 专网自行获取 DHCP 租约，专网路由与源 IP 随租约自动维护，无需
RouterOS SNAT/静态路由（RouterOS 只做二层桥接 + IGMP 组播代理）。

## 结构

- `install.sh`：PVE 一键引导。无参数运行=交互向导（扫描空闲 CT 号/管理 IP、冲突
  重输、机顶盒抓包/手工）；也支持参数化透传。首次从本仓库 tag 下载同版本包。
- `pve-iptv-dhcp-create.sh`：PVE 编排。**默认自包含**：自动把本仓库 `app/` 打包
  推入新 CT 作为应用发行包，全程不访问其它仓库；也可 `--pkg-dir <dir>` 指定本地
  发行目录。其它参数（--vmid/--mgmt-ip/--eth1-mac/--ssh-pubkey/--routeros-key/
  --template/--destroy-existing/...）见脚本内 `--help`。
- `install-dhcp.sh`：CT 内引导。eth1 DHCP + dhclient hooks（专网路由/源 IP 随租约
  维护、config.yaml `stb.ip` 自动同步）；机顶盒参数支持 `STB_MODE=manual` 与
  `STB_MODE=capture`（RouterOS 抓包）；本地 MariaDB + config.yaml + systemd。
  GitHub 兜底下载只指向本仓库 Release（`iptv-spider-app-<ver>-linux-amd64.tar.gz`）。
- `app/`：应用本体（iptv-spider 源码 + assets/logos + `status.sh`/`manage.sh`/
  `uninstall.sh`/覆盖升级 `install.sh`/自动更新 `update.sh` 等）。**`app/bin/`
  的二进制不入库**，只随 Release 应用资产发布。
- `build-app.sh`：维护者用。从 `app/` 源码构建 `bin/` 两个二进制，并打包
  `iptv-spider-app-<版本>-linux-amd64.tar.gz` + `.sha256`。
- `build-release.sh`：维护者用。打包安装件 `iptv-spider-pve-<tag>.tar.gz` + `.sha256`；
  固定 mtime/属主/权限/排序，同样内容产出同样字节，且工作区与目标 ref 不一致时直接报错。
- `docs/`：RouterOS 侧参考文档。

### 版本号约定

| 概念 | 取值 | 出现位置 |
|---|---|---|
| 仓库 tag | `v0.3.4`（安装器/整包版本） | Release 标签、`install.sh` 的 `VERSION` |
| 应用版本 | `1.2.5`（`app/VERSION`） | 应用资产文件名、`install-dhcp.conf` 的 `VERSION` |

`install-dhcp.conf` 里：`VERSION` = 应用版本（决定资产文件名），`REPO_TAG` = 本仓库
Release 标签（决定资产所在路径）。

## 快速开始（全新安装）

前置：Proxmox VE root Shell；Debian 12 CT 模板
（`local:vztmpl/debian-12-standard_*.tar.zst`）；RouterOS 侧已有 VLAN85 二层路径；
`STB_MODE=capture` 需实体机顶盒可断电上电。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/driftbottle61/iptv-spider-pve/v0.3.4/install.sh)
```

- 无参数=交互向导；按提示选择机顶盒参数获取方式（RouterOS 抓包 / 手工）。
- 抓包模式下：向导只登记 RouterOS 连接参数，真正抓包在 CT 建好、专网 DHCP 就绪后
  自动开始，届时按提示断电重启机顶盒。
- 安装完成会显示：TiviMate `http://<管理IP>:8888/tv.m3u`、IPTV#
  `http://<管理IP>:8888/iptvsharp.m3u`、EPG `http://<管理IP>:8888/api/epg?daysAgo=7`。
- CT 内 `iptv-spider-status` 会显示同样三个链接；管理菜单 `iptv-spider`。

## 自动更新（已装节点）

CT 内自带更新器，默认每天自动检测本仓库 Release 的应用包，有新版本就自动安装：

```bash
iptv-spider-update              # 检测并更新（有新版本才动）
iptv-spider-update --check      # 只检测（有新版本时退出码 10）
iptv-spider-update --status     # 本机版本 + 最近检测结果
```

管理菜单 `iptv-spider` 的 6/7 项可手动检查更新、切换"自动安装/仅检测/关闭定时"。
更新只替换程序与脚本，保留 `config.yaml`、数据库、`eth1` 专网配置；先做 SHA256
校验，再备份到 `*.update-backup.<时间戳>`（保留最近 3 份），启动不稳定则自动回滚。
开关与说明见 `/etc/iptv-spider/update.conf` 与 `app/README_CN.md` 的「自动更新」。

## 自包含说明

- 全新安装：`install.sh` → 本仓库 tag 包 → `pve-iptv-dhcp-create.sh` 默认使用
  `app/` 本地发行包 → CT 安装全程无外部仓库依赖。
- 需要全程离线/不访问 GitHub：把 Release 的应用资产解包到脚本同目录（得到
  `app/bin/`），再运行 `install.sh`，即走"本地发行包"路径。
- 已装节点覆盖升级：CT 内 `/opt/sh-iptv-spider/install.sh`（app 自带），或重跑
  一键安装选择全新 CT。
- 卸载：CT 内 `iptv-spider-uninstall`。

## 维护者发布流程

1. 改 `app/` 源码（或安装件）→ 应用有变动时递增 `app/VERSION`。
2. `./build-app.sh` 构建 `app/bin/` 并生成应用资产（含 `.sha256`）。
3. 同步版本钉：`install.sh`（仓库 tag）、`install-dhcp.conf.example` 与
   `pve-iptv-dhcp-create.sh` 的 answer 模板（`VERSION`/`REPO_TAG`）、
   `app/install-oneclick.sh` 与 `app/pve-iptv-prep-oneclick.sh`（同上）、
   `app/tests/installer_static_test.sh`、`docs/`。
4. `app/tests/installer_static_test.sh` 自检通过后，打 tag（`vX.Y.Z`）并推 main。
5. `./build-release.sh <tag>` 生成安装件资产（在 tag 对应的提交上运行）。
6. 建 Release，上传两个资产：`iptv-spider-pve-<tag>.tar.gz`(+`.sha256`，安装件）与
   `iptv-spider-app-<appver>-linux-amd64.tar.gz`(+`.sha256`，应用包）。

应用运行细节、RouterOS 抓包说明、配置项见 `app/README_CN.md`。

## 参考文档与致谢

- `docs/routeros-iptv-guide-jeffz.md`：RouterOS + 猫棒打通上海电信 IPTV 二层
  链路指引。整理自 jeffz 的博客文章《上海电信 IPTV 折腾记录 ROS+猫棒》
  （<https://jeffz.page/posts/4277824729/>）。本项目的 RouterOS 猫棒 IPTV
  链路即参考 jeffz 的文章打通，在此致谢。
