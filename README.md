# YOpenWrt-CI

自用 OpenWrt 云编译仓库。上游：[VIKINGYFY/OpenWRT-CI](https://github.com/VIKINGYFY/OpenWRT-CI)（MIT）。

---

## 一、两台设备

| 机器 | 配置 | 硬件 | 关键差异 |
| --- | --- | --- | --- |
| 京东云亚瑟 RE-SS-01 / AX1800 Pro | `JDCloud-noWiFi` | IPQ6000，1GB 硬改内存 + **64GB eMMC**，带 USB 口 | 空间富余，装存储类插件（分区扩容 / 磁盘管理 / 文件共享）+ **Docker** + UPnP |
| 兆能 ZN-M2 | `ZNM2-noWiFi` | IPQ6000，512MB 内存 + **128MB NAND**，无 WiFi、无 USB 口 | 空间紧张，做减法；存储类 / Docker / UPnP 都不装，另加 **zram** 防 OOM |

两台都是**无 WiFi 版**：无线驱动（ath11k 及固件）在各自配置里显式关掉。

## 二、三条源码线

每条工作流运行时用一个下拉框选，一次只出一条线的固件。

| 选项 | 仓库 / 分支 | 内核 | 特点 |
| --- | --- | --- | --- |
| `LibWrt` | `LiBwrt/LibWrt` @ `25.12-nss` | 6.12 | NSS 加速 + WiFi 卸载，最成熟 |
| `OWrt-NSS` | `VIKINGYFY/immortalwrt` @ `main` | 6.18 | NSS 加速 |
| `OWrt-PPE` | `VIKINGYFY/immortalwrt` @ `owrt` | 6.18 | PPE 加速（上游新 edma/ppe 架构），追新 |

## 三、目录结构

```
.github/workflows/    CI 配置
  WRT-CORE.yml        公用编译核心（被其它工作流用 uses: 调用，自己不触发）
  JDCloud-noWiFi.yml  亚瑟
  ZNM2-noWiFi.yml     兆能 M2
  WRT-TEST.yml        只出 .config、不编固件（默认 TEST=true）
  Auto-Clean.yml      清 Release / 运行记录（自动定时已注释停用）
  Cache-Clean.yml     清编译缓存（自动定时已注释停用）
Scripts/              自定义脚本（Packages.sh 拉第三方插件 / Handles.sh 打补丁 / Settings.sh 改默认值）
Config/               自定义配置（.config 后缀）
```

## 四、配置文件怎么分层

```
机型配置 → GENERAL.config → Settings.sh 注入 → make defconfig
```

| 文件 | 内容 |
| --- | --- |
| `Config/JDCloud-noWiFi.config` | 平台 + 亚瑟设备 + 关无线 + **存储与文件共享**（diskmanager / partexp / samba4 / block-mount / e2fsprogs / parted + `kmod-fs-ext4` / `vfat` / `exfat`）+ **UPnP** + **Docker 全套**（含内核开关）+ lucky / adguardhome / emmc-health / vlmcsd |
| `Config/ZNM2-noWiFi.config` | 平台 + M2 设备 + 关无线 + **zram**（512MB 内存的低内存保护） |
| `Config/GENERAL.config` | 两台共用的内核模块 / 组件 / 插件；插件按用途分小类（科学上网 / 组网 / 远程访问 / 日常工具 / 命令行工具） |
| `Config/TEST.config` | 测试用，自包含（含一份 GENERAL 的副本，改通用层时记得同步） |

## 五、怎么用

全部手动触发，没有任何自动编译：

- **改完配置先跑测试**：Actions → `WRT-TEST` → 选配置和源码线 → `TEST` 保持 `true` → Run。
  几分钟出一份 `.config`，能直接看出哪些包被 defconfig 真正选中。
- **正式出固件**：Actions → `JDCloud-noWiFi` 或 `ZNM2-noWiFi` → 选源码线 → Run（约 1.5~3 小时）。
  产物在 Releases：固件 + 本次用的完整 `.config`。

刷机后：

- 管理地址：OWrt 线（NSS / PPE）`192.168.10.1`，LibWrt 线 `192.168.20.1`
  （在对应工作流的 `WRT_IP` 里改）
- 默认密码：空（首次登录时设置）
- 主机名 / 主题：`OWrt`（或 `LibWrt`，随源码线）/ `argon`

## 六、几条规则（都是踩过坑的，别改回去）

- **关包必须显式写 `=n`**。`target/linux/qualcommax/Makefile` 的 `DEFAULT_PACKAGES` 自带
  `autocore automount cpufreq e2fsprogs f2fs-tools losetup luci uboot-envtools wpad-openssl`
  （LibWrt 那条线还额外带 **`luci-app-cpufreq`**）。把配置行**注释掉**等于回落到 target 默认值，
  包照样进固件 —— 10-20 实测：`cpufreq=y` 注释掉后，M2 的 LibWrt 固件里 cpufreq 依然在。
  现在 `cpufreq` / `luci-app-cpufreq` 在通用层 `=n`，`wpad-openssl` / `hostapd-common`
  在两份 noWiFi 配置里 `=n`，别再改回注释。
- **只要有一台机器不要的包就不能留在 `GENERAL.config`**（它的 `=y` 会覆盖机型层的 `=n`）。
  USB / SATA / NVMe / 声卡相关已整批下放到 `JDCloud-noWiFi.config`，
  并在 `ZNM2-noWiFi.config` 里显式 `=n` 关掉（M2 没有这些接口）。
- **「界面 + 主程序」要两行都写 `=y`**：`DEPENDS` 生成的是 `depends on`，依赖只会被提到 `=m`
  （编成 ipk、不进固件镜像）。docker 全套、upnp（+`miniupnpd`）都栽过。
- **`=m` 是刻意的「编成 apk、不进固件」**：`adguardhome` / `lucky` / `vlmcsd` / `easytier`
  在 `JDCloud-noWiFi.config` 里写成 `=m`（界面 + 主程序 + 中文包三行都要改）。
  它们的 apk 由 `WRT-CORE.yml` 从 `bin/packages` 挑出来随 Release 发布
  （Release 默认只收 `bin/targets`，不拷就等于白编）；刷完 `apk add <包名>` 装上，
  再 `rm -f /tmp/luci-indexcache*` 刷新菜单。依赖同是 `=m`，离线装要连依赖的 apk 一起装。
  `adguardhome` / `vlmcsd` 在官方 feeds 里，也可走在线源装；`lucky` / `easytier` 官方源没有。
- **抄别人的清单前先核对符号是否存在**：`nftables`（主干只有 `nftables-json` / `nojson`）、
  `DOCKER_OPTIONAL_FEATURES`（它 select 的两个符号在 6.x 已移除）这类写了会被静默丢掉。
- **TEST 只做 `defconfig`、不编译**：补丁打不上、源码下载失败都测不出来，
  新增大功能后每条要用的源码线至少真编一次。
