# RouterOS + 猫棒打通上海电信 IPTV：二层链路指引

> **转载与鸣谢**
>
> 本文整理转载自 jeffz 的博客文章《上海电信 IPTV 折腾记录 ROS+猫棒》：
>
> - 作者：jeffz（jeffz.page）
> - 原文链接：<https://jeffz.page/posts/4277824729/>
> - 整理日期：2026-09-09
>
> 本项目部署的 RouterOS（猫棒 + VLAN 桥接）二层链路，正是参考 jeffz 的这篇
> 文章打通的，在此向 jeffz 致谢。原文以 WinBox 配置截图为主，本仓库转载仅
> 保留文字，配置步骤截图请以原文为准。

## 与 iptv-spider-pve 的关系

iptv-spider-pve 采用 DHCP-direct 架构：RouterOS 侧只承担二层接入——EPON
猫棒出来的专网 VLAN（`pon-vlan85` / `pon-vlan51`）与下联到 PVE/交换机的
`lan-vlan85` 加入同一个 Bridge，构成机顶盒 / CT 到上海电信 IPTV 专网的
二层通路；专网三层（DHCP 租约、认证、EPG、回放）由 IPTV Spider 所在 CT
在 VLAN85 上 DHCP 直连完成，RouterOS 不需要 SNAT 与静态路由（详见根目录
README）。

因此，把上面这段"二层链路"在 RouterOS 上打通，是运行一键安装
（`bash <(curl -fsSL https://raw.githubusercontent.com/driftbottle61/iptv-spider-pve/v0.3.8/install.sh)`）
之前 RouterOS 侧的必备前提。下面 jeffz 的文章正文正是这一段的可执行参考。

---

## 原文正文：上海电信 IPTV 折腾记录 ROS+猫棒

### 背景

最近家里升级了 2000M 宽带，原来的光猫只有 1G 口，没法跑满 2000M 宽带，
故更换了 MikroTik RB5009 和 10G EPON 猫棒。但是家里还是需要观看 IPTV，
所以需要在 RouterOS 上设置。

### 1. 先确认 PPPoE 拨号成功

首先要确保换了猫棒之后 PPPoE 拨号是成功的。

### 2. 建立 VLAN85 与 VLAN51

接下来开始设置 VLAN85 和 VLAN51，还有 LAN 口的 VLAN85。

### 3. 新建 Bridge 并把接口加入

接下来设置一个新的 Bridge，把刚才添加的接口都加入进去。

> （2025/04/24 更新：有外地群友反映打开了 IGMP Snooping 可能会导致无法
> 正常使用，关闭后正常。）

### 4. 配置 DHCP option 125

由于上海电信 IPTV 还需要 DHCP option 125：在 WinBox 内点击
IP → DHCP Server，按原文截图进行设置，关键值如下：

```text
1 | 0x000000001a02064847572d435403045a58484e0a0220000b0200550d02002e
```

记得勾选 **Force** 选项；再按原文截图设置 DHCP Options。

### 5. 验证

现在就可以打开 IPTV 盒子，愉快地观看 IPTV 了。

---

## 版权声明

内容版权归原作者 jeffz 所有，此处仅作为学习与排障参考转载；如需再转载或
商用，请以原文授权为准。
