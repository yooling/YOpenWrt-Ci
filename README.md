# YOpenWrt-CI

自用 OpenWrt 云编译仓库。上游：[VIKINGYFY/OpenWRT-CI](https://github.com/VIKINGYFY/OpenWRT-CI)（MIT）。

上游是一套「多平台 × 多机型」的通用编译器；本仓库把它收敛成**两台自用机器**的量级：
只保留 IPQ60xx 一个平台、两台设备的配置，除必要项外一律不改动上游逻辑 —— 上游更新时可以整份替换核心文件。

---

## 一、两台设备

| 机器 | 配置 | 硬件 | 关键差异 |
| --- | --- | --- | --- |
| 京东云亚瑟 RE-SS-01 / AX1800 Pro | `JDCloud-noWiFi` | IPQ6000，1GB 硬改内存 + **64GB eMMC**，带 USB 口 | 空间富余，装存储类插件（分区扩容 / 磁盘管理 / 文件共享）+ **Docker** |
| 兆能 ZN-M2 | `ZNM2-noWiFi` | IPQ6000，512MB 内存 + **128MB NAND**，无 WiFi、无 USB 口 | 空间紧张，做减法；存储类插件一个不装，**也不装 Docker** |

两台都是**无 WiFi 版**：无线驱动（ath11k 及固件）在各自配置里显式关掉。

## 二、三条源码线

每条工作流运行时用一个下拉框选，一次只出一条线的固件。

| 选项 | 仓库 / 分支 | 内核 | 特点 |
| --- | --- | --- | --- |
| `LibWrt` | `LiBwrt/LibWrt` @ `25.12-nss` | 6.12 | NSS 加速 + WiFi 卸载，最成熟 |
| `OWrt-NSS` | `VIKINGYFY/immortalwrt` @ `main` | 6.18 | NSS 加速 |
| `OWrt-PPE` | `VIKINGYFY/immortalwrt` @ `owrt` | 6.18 | PPE 加速（上游新 edma/ppe 架构），追新 |

> 分支**不单独给输入框**：GitHub 的 `workflow_dispatch` 表单不支持联动，留空输入框会被浏览器
> autofill 成旧值 `main`，结果是「选了 PPE 却拉到 main 分支」。现在仓库/分支/主机名都由这一个
> 下拉框带出，没有第二处要填。

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

**后加载的覆盖先加载的。** 由此得出两条硬规则：

1. **机型层写这台机器特有的，通用层只写两台都要的。**
2. **只要有一台机器不要的包，就不能留在 `GENERAL.config`** —— 它的 `=y` 会把机型层写的
   `=n` 反向覆盖回 `=y`（这是旧项目实际的踩坑点：M2 的减法一句都没生效）。

| 文件 | 内容 |
| --- | --- |
| `Config/JDCloud-noWiFi.config` | 平台 + 亚瑟设备 + 关无线 + **存储三件套**（diskmanager / partexp / samba4）+ **Docker 全套**（含内核开关、`rootfs` 分区调大） |
| `Config/ZNM2-noWiFi.config` | 平台 + M2 设备 + 关无线 + 存储三件套不打（注释说明原因，需要时取消注释） |
| `Config/GENERAL.config` | 两台共用的内核模块 / 组件 / 插件；插件按用途分小类（科学上网 / 网络向导·组网 / 远程访问·内网穿透 / 日常工具） |
| `Config/TEST.config` | 测试用，自包含（含一份 GENERAL 的副本，改通用层时记得同步） |

## 五、相对上游改了什么

改动刻意压到最小，只有这几处：

1. **配置后缀 `.txt` → `.config`**（`WRT-CORE.yml`、`Settings.sh`、`.gitattributes` 同步调整）。
2. **只留两台机器的配置**，其余机型配置删除；`Auto-Clean` / `Cache-Clean` 的 `schedule` 用注释停用（文件保留，手动仍可跑）。
3. **`GENERAL.config`** 的插件段按用途分了小类，加新插件时放进对应分类（没有就新建一个）：
   - **科学上网**：关 `luci-app-homeproxy`（不用）；加 `luci-app-nikki` + 中文语言包
     （sing-box 内核，darkrain88 那份同样默认开着，上游 `Packages.sh` 已默认 clone 该源）；
   - **网络向导·组网**：加 **`luci-app-netwiz`**（NetWiz，huchd0 的网络设置向导，改上网方式的第一入口，
     不能写成 `=m` —— 不进固件刷完菜单里看不到）
     ⚠ 不是 sirpdboy 的 `luci-app-netwizard`，两者名字只差两个字母、别写错；
     `Packages.sh` 里因此单独手写了一段 clone（该仓库的仓库名与包目录同名，`UPDATE_PACKAGE`
     的 `pkg` 模式会把包嵌套复制后又删掉），**并在 clone 后 chmod 755 补齐 8 个脚本的执行位**
     —— 该仓库源码里这些脚本没有执行位，`luci.mk` 装包用 `cp -pR` 会原样保留，
     编进固件就会导致 `rpcd` 加载不到 `netwiz` 对象（前端全部报 `-32000 Object not found`）、
     防失联回滚脚本也跑不起来。详见 `Packages.sh` 里那段「必做」注释；
     另加 `luci-app-easytier`（异地组网，打不通自动走中继）；
     停用 `luci-app-natmapt` 与配套 `stuntman-client`
     —— 本机家宽 NAT3~NAT4、无公网 IPv6，打洞类方案根本打不通；
   - **远程访问·内网穿透**：加 **`ddnsto` + `luci-app-ddnsto`**（官方包仓库
     `linkease/ddnsto-openwrt-package`）。和 EasyTier 不冲突：EasyTier 是组网（连上等于人在家里），
     DDNSTO 是单点穿透（把某个网页 / 端口映射到外网，不用装客户端），且走服务端中转、
     不受 NAT3~NAT4 限制。版本是「主程序 4.2.6 + 界面 4.2.2」，官方仓库当前就这个组合，
     详见 `GENERAL.config` 里的注释；
   - **日常工具**：`autoreboot` / `upnp` / `wolultra`；
   - 删 `luci-app-gecoosac`；
   - 把 `mini-diskmanager` / `partexp` / `samba4` 三个**存储类**插件下放到 `JDCloud-noWiFi.config`
     —— 它们是给有 eMMC 可扩容、能接盘的机器用的，M2（128MB NAND、无 USB 口）用不上。
4. **`WRT-TEST.yml`**：下拉框只列本仓库的两份配置 + `TEST`，源码线与正式工作流同一套。
5. **管理地址按源码线分网段**：OWrt 两条线 `192.168.10.1`、LibWrt `192.168.20.1`
   （两条线的固件在同一网络里不会撞 IP）。
6. **Docker（只给亚瑟）**：`Config/JDCloud-noWiFi.config` 里选 `luci-app-dockerman` + 中文包 +
   `docker-compose` + `iptables-nft` + `kmod-macvlan`，源码用 `XiaoHaiSly/luci-app-dockerman`
   （整套版本由作者仓库每天自动跟 moby 发版同步，不用自己追）。
   配套改了三样，`Packages.sh` 里都有「必做」注释：
   - **内核开关**：`CONFIG_KERNEL_NAMESPACES / CGROUPS / MEMCG / SECCOMP / POSIX_MQUEUE …` 一大组。
     上游 `target/linux/generic/config-6.18` 里这些默认全是 `is not set`，不开容器起不来；
   - **`CONFIG_TARGET_ROOTFS_PARTSIZE=512`**：默认 rootfs 分区只有 104MB，装不下 docker，
     打包时 `pad-rootfs` 会直接报「rootfs 太大」中断编译；亚瑟是 64GB eMMC，给 512MB 很宽裕；
   - **三个补丁**：① `runc` 的 `include ../../lang/golang/...` 相对路径改绝对路径（它原本只在
     `feeds/packages/utils/` 下成立）；② `docker` CLI 校验 commit 时的
     `$(CURDIR)/../dockerd/git-short-commit.sh` 改绝对路径；③ 删掉 `dockerd` 对 `uci-firewall`
     的依赖 —— 这个包在 immortalwrt / openwrt 的 feeds 和主干里都搜不到，依赖解析不了会中断编译，
     而 `dockerd.init` 只用 `uci` 命令改防火墙，并不需要它。
   另外 feeds 里自带的一套老 `docker` / `dockerd` / `docker-compose` 会整包重名，
   `Packages.sh` 里已顺手清掉（含 `package/feeds/` 下的软链接）。

`Scripts/Packages.sh` 除上游原样外，只注释了 natmapt 三件套（配合上面停用）、
新增了 DDNSTO 与 Docker 两段（含各自的补丁）；
`Handles.sh` / `Settings.sh` 与上游完全一致，`WRT-CORE.yml` 除第 1 点外也与上游一致。

## 六、怎么用

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
- Docker（仅亚瑟）：数据目录默认 `/opt/docker`，服务 `/etc/init.d/dockerd`，
  想在局域网里直接访问容器用 macvlan（对应包已装）

## 七、几个已踩过的坑（别改回去）

- **关包必须显式写 `=n`**。ipq60xx 的 `DEFAULT_PACKAGES` 自带一整套包（ath11k、kmod-usb3、
  kmod-fs-ext4、automount …），把配置行**注释掉**等于用 target 的默认值，包照样进固件。
- **设备列表只列自己那台**。列了就会一起编进固件包，体积和编译时间都翻倍。
- **别往 `GENERAL.config` 加只有一台机器要的包**，理由见第四节第 2 条。
- **Docker 的两条连带项不能省**：只写 `luci-app-dockerman=y` 而不开那组 `CONFIG_KERNEL_*`，
  容器起不来；不调 `CONFIG_TARGET_ROOTFS_PARTSIZE`，打包阶段就断。两者都写在
  `JDCloud-noWiFi.config` 里，改配置时别当成冗余删掉。
- **第三方 Go 包（docker / containerd / runc / compose）会显著拉长编译时间**
  （Go 工具链 + 大仓库编译），亚瑟那条线会比 M2 慢不少，是正常的。
