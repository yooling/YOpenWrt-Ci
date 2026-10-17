# YOpenWrt-CI

自用 OpenWrt 云编译仓库。上游：[VIKINGYFY/OpenWRT-CI](https://github.com/VIKINGYFY/OpenWRT-CI)（MIT）。

上游是一套「多平台 × 多机型」的通用编译器；本仓库把它收敛成**两台自用机器**的量级：
只保留 IPQ60xx 一个平台、两台设备的配置，除必要项外一律不改动上游逻辑 —— 上游更新时可以整份替换核心文件。

---

## 一、两台设备

| 机器 | 配置 | 硬件 | 关键差异 |
| --- | --- | --- | --- |
| 京东云亚瑟 RE-SS-01 / AX1800 Pro | `JDCloud-noWiFi` | IPQ6000，1GB 硬改内存 + **64GB eMMC**，带 USB 口 | 空间富余，装存储类插件（分区扩容 / 磁盘管理 / 文件共享）+ **Docker** + **iStore / QuickStart** |
| 兆能 ZN-M2 | `ZNM2-noWiFi` | IPQ6000，512MB 内存 + **128MB NAND**，无 WiFi、无 USB 口 | 空间紧张，做减法；存储类插件一个不装，**也不装 Docker / iStore** |

> **网络向导两台各用一套**：亚瑟用 QuickStart 里的 **NetworkGuide**，M2 用 **NetWiz**。
> 所以 NetWiz 不在通用层，而是写在 `ZNM2-noWiFi.config` 里（见第五节第 3 点）。

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
| `Config/JDCloud-noWiFi.config` | 平台 + 亚瑟设备 + 关无线 + **存储三件套**（diskmanager / partexp / samba4）+ **iStore / QuickStart 全套** + **Docker 全套**（含内核开关、`rootfs` 分区调大） |
| `Config/ZNM2-noWiFi.config` | 平台 + M2 设备 + 关无线 + **NetWiz**（M2 的网络向导）+ 存储三件套不打（注释说明原因，需要时取消注释） |
| `Config/GENERAL.config` | 两台共用的内核模块 / 组件 / 插件；插件按用途分小类（科学上网 / 组网 / 远程访问·内网穿透 / 日常工具） |
| `Config/TEST.config` | 测试用，自包含（含一份 GENERAL 的副本，改通用层时记得同步） |

## 五、相对上游改了什么

改动刻意压到最小，只有这几处：

1. **配置后缀 `.txt` → `.config`**（`WRT-CORE.yml`、`Settings.sh`、`.gitattributes` 同步调整）。
2. **只留两台机器的配置**，其余机型配置删除；`Auto-Clean` / `Cache-Clean` 的 `schedule` 用注释停用（文件保留，手动仍可跑）。
3. **`GENERAL.config`** 的插件段按用途分了小类，加新插件时放进对应分类（没有就新建一个）：
   - **科学上网**：关 `luci-app-homeproxy`（不用）；加 `luci-app-nikki` + 中文语言包
     （sing-box 内核，darkrain88 那份同样默认开着，上游 `Packages.sh` 已默认 clone 该源）；
   - **组网**：停用 `luci-app-natmapt` 与配套 `stuntman-client`
     —— 本机家宽 NAT3~NAT4、无公网 IPv6，打洞类方案根本打不通；
     **网络向导不写在通用层**（两台各用一套，见下面第 7 点）；
     **EasyTier 也不在通用层**（只给亚瑟，见下面第 8 点）；
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
6. **Docker（只给亚瑟）**：源码用 `XiaoHaiSly/luci-app-dockerman`
   （整套版本由作者仓库每天自动跟 moby 发版同步，不用自己追）。
   `Config/JDCloud-noWiFi.config` 里**整套每一项都显式写了 `=y`**：
   `dockerd` / `docker` / `containerd` / `runc` / `luci-lib-docker` / `tini` / `nftables-json` /
   `luci-app-dockerman` + 中文包 / `docker-compose` / `iptables-nft` / `kmod-macvlan` ——
   **只写 `luci-app-dockerman=y` 是不够的**，原因见第七节「靠依赖自动带出来」那条。
   配套改了三样，`Packages.sh` 里都有「必做」注释：
   - **内核开关**：`CONFIG_KERNEL_NAMESPACES / CGROUPS / MEMCG / SECCOMP / POSIX_MQUEUE …` 一大组。
     上游 `target/linux/generic/config-6.18` 里这些默认全是 `is not set`，不开容器起不来；
   - ~~`CONFIG_TARGET_ROOTFS_PARTSIZE=512`~~ **已注释掉，因为这行在亚瑟身上根本不生效**：
     TEST 实证生成的 `.config` 里这个符号**完全不存在**。原因是它在 `Config-images.in` 里写着
     `depends on USES_ROOTFS_PART || TARGET_ROOTFS_EXT4FS`，而亚瑟是 EmmcImage（squashfs + eMMC），
     两个条件都不满足 → 符号不可见，写了也白写。对 64GB eMMC 本来也不需要它
     （按分区表直接写入，没有那个小分区限制）。留成注释备用，详见第七节；
   - **三个补丁**：① `runc` 的 `include ../../lang/golang/...` 相对路径改绝对路径（它原本只在
     `feeds/packages/utils/` 下成立）；② `docker` CLI 校验 commit 时的
     `$(CURDIR)/../dockerd/git-short-commit.sh` 改绝对路径；③ 删掉 `dockerd` 对 `uci-firewall`
     的依赖 —— 这个包在 immortalwrt / openwrt 的 feeds 和主干里都搜不到，依赖解析不了会中断编译，
     而 `dockerd.init` 只用 `uci` 命令改防火墙，并不需要它。
   另外 feeds 里自带的一套老 `docker` / `dockerd` / `docker-compose` 会整包重名，
   `Packages.sh` 里已顺手清掉（含 `package/feeds/` 下的软链接）。
   依赖清单是**逐项核过** ZqinKing 的 `docker_deps.config` 之后定的，只采纳了 3 项
   （`kmod-nf-ipvs` / `kmod-br-netfilter` / `libseccomp`）；他那份里剩下的
   `kmod-ipt-*` 那一批是 iptables 旧后端遗留（v29 dockerd 已全面走 nftables），
   `kmod-crypto-*` / `kmod-lib-*` 是 btrfs 的底层依赖（通用层已开 `kmod-fs-btrfs`，会自动带出），
   `nftables` 这个符号本身不存在 —— 详见 `JDCloud-noWiFi.config` 里的判定注释。
7. **iStore / QuickStart（只给亚瑟）**：成品界面是
   `https://<路由>/cgi-bin/luci/admin/quickstart/` 那一页，菜单含
   **QuickStart 仪表盘 / NetworkGuide 网络向导 / NetworkPort 网口配置 / iStoreX 首页 / iStore 商店**。
   入口包是 `luci-app-istorex`，它的 `LUCI_DEPENDS` 会自动带出
   `luci-app-quickstart` + `luci-app-store` + `luci-lib-taskd` ——
   但**依赖带出来的是 `=m`（编成包、不进固件镜像），刷完菜单里看不到**，
   所以 `JDCloud-noWiFi.config` 里把每一个要用的包都显式写成了 `=y`。
   同理，`ttyd`（网页终端主程序，界面是 `luci-app-ttyd`）、`sqm-scripts`（SQM 真正的限速脚本）
   也各自单独写了 `=y`；`quickstart` 后端 DEPENDS 里那批命令行工具
   （`bash` / `block-mount` / `mount-utils` / `e2fsprogs` / `parted` / `smartd` /
   `shadow-utils` / `shadow-useradd`）一并钉成 `=y` —— 缺了它们向导页会在运行时报错。
   配套还有 `lucky` / `adguardhome` / `emmc-health` / `sqm` / `vlmcsd` / `quickfile`
   （`oaf` 已停用，理由见第七节）。
   三个必打补丁（理由都写在 `Packages.sh` 里）：
   - `quickstart` 去掉 `+mdadm`（软 RAID，用不上还会拖进一堆 `kmod-md-*` 内核模块）；
   - `luci-app-adguardhome` 的 `+ca-certs` 改成 `+ca-certificates`（前者源码树里根本没有）；
   - `luci-app-emmc-health` 去掉 `+luci-js-deps`（主干里没有这个包）。
   **明确剔除**：`passwall` / `mosdns` / `smartdns` / `cups` 打印 / `pbr` 策略路由 /
   `athena-led`（京东云雅典娜专属）—— 这些在 `JDCloud-noWiFi.config` 末尾留了注释留档。
   网络唤醒沿用 `wolultra`（带定时开机），不换官方 `wol`。
8. **EasyTier（只给亚瑟）**：`luci-app-easytier` + `luci-i18n-easytier-zh-cn` + **`easytier`（主程序）**
   三行都写在 `JDCloud-noWiFi.config` 的「组网」段。
   ★**主程序必须单独显式写 `=y`**：`luci-app-easytier` 的 `LUCI_DEPENDS` 只有
   `+kmod-tun +luci-compat` —— **压根没依赖主程序**。只写界面那行的话，编出来是
   「菜单在、`easytier-core` 不在」，点了完全没用（2026-10-17 的 TEST 已实证：
   `CONFIG_PACKAGE_easytier` 是 `is not set`，界面却是 `y`）。
   ★**不给 M2 的原因**：主程序是 Rust 写的二进制，且 Makefile 里 `RSTRIP:=:` 明确禁止 strip
   —— 压缩包 10~24MB，解压后 40~70MB，M2 只有 128MB NAND 装不下；亚瑟 64GB eMMC 无所谓。
9. **`WRT-CORE.yml`：TEST 模式下把关键包的选中状态直接打到日志里**（新增在「Package Firmware」步骤）。
   原因：`.config` 是当 Artifact 上传的、不在 logs 里，每次单独下载太麻烦；
   而且第三方包靠依赖带出来的经常是 `=m`（编成包但不进固件镜像，刷完菜单里看不到），
   光看「编译成功」发现不了。现在跑完 TEST 直接在日志里就能看到每一项是 `y` / `m` / 没选上，
   顺带打印那组 docker 内核开关和 `ROOTFS_PARTSIZE` 有没有真的生效。
   输出会**区分两种「没选上」**，这点很关键：`n（包在但没选上 —— 显式写 =y 可救）` 指的是
   `.config` 里有 `# CONFIG_PACKAGE_xxx is not set`，包在源码树里、只是没选中；
   `符号不存在（源没拉到 / 包名写错）` 指的是 kconfig 压根不认这个符号。
   前者补一行 `=y` 就好，后者要回头查源有没有拉到。EasyTier 的坑正是靠这个区分抓出来的。

`Scripts/Packages.sh` 除上游原样外，只注释了 natmapt 三件套（配合上面停用）、
新增了 DDNSTO、Docker、iStore / QuickStart、eMMC-Health 四段（含各自的补丁）；
OAF 那段写了又停用了（理由见第七节），同样以注释形式保留。
`Handles.sh` / `Settings.sh` 与上游完全一致，`WRT-CORE.yml` 除了第 1、9 点外也与上游一致。

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
- **Docker 的内核开关不能省**：只写 `luci-app-dockerman=y` 而不开那组 `CONFIG_KERNEL_*`，
  容器起不来。开关都写在 `JDCloud-noWiFi.config` 里，改配置时别当成冗余删掉。
  （`CONFIG_TARGET_ROOTFS_PARTSIZE` 不算连带项 —— 它在亚瑟身上压根不生效，见下一条。）
- **第三方 Go 包（docker / containerd / runc / compose）会显著拉长编译时间**
  （Go 工具链 + 大仓库编译），亚瑟那条线会比 M2 慢不少，是正常的。
- **「靠依赖自动带出来」不等于装进固件**。依赖链上的包被 `defconfig` 选中时是 `=m`
  （只编成包、不进 rootfs 镜像），刷完菜单里看不到 —— iStore 那套和 Docker 那套
  都必须把用到的每一项显式写成 `=y`，别只写 `luci-app-istorex=y` 就以为完事了。
- **第三方 Makefile 写的依赖未必真的存在**，apk 体系下解析不了是**直接中断编译**。
  已踩到三个：`uci-firewall`（dockerd）、`ca-certs`（adguardhome）、`luci-js-deps`（emmc-health）。
  加新的第三方包前先确认它的 `DEPENDS` 每一项都能在源码树/feeds 里找到。
- **iStore 商店里的软件来自 istore 在线源**，跟自编译固件不一定匹配，
  `kmod` 类基本装不上 —— 只当应用层软件入口用。
- **TEST 只做 `make defconfig`，不编译**。它能验证「包有没有被选中、内核符号有没有效、
  第三方 Makefile 的依赖能不能解析」，但**验证不了**：① out-of-tree 内核模块在这些内核下
  能否编译过；② `lucky` / `easytier` 那种在 `Build/Prepare` 里 `wget` 拉二进制的包能不能下到
  （TEST 阶段根本不执行，正式编译才会去 GitHub 拉）。三条 TEST 全过 ≠ 正式编译一定过。
- **判断补丁有没有生效，看 defconfig 的 WARNING 列表**。第三方 Makefile 写了不存在的依赖，
  `make defconfig` 一定会打印 `WARNING: Makefile '…' has a dependency on 'xxx', which does not exist`。
  2026-10-17 首轮 TEST（ZNM2 × OWrt-NSS / LibWrt）日志里没有 `ca-certs` / `luci-js-deps` /
  `uci-firewall` 的警告 → 那三个补丁确认生效。这是最快的验证办法。
- **OAF 已停用**（`destan19/OpenAppFilter`）。原因是三条叠加，最后一条是决定性的：
  ① defconfig 报 `symbol PACKAGE_kmod-oaf is selected by PACKAGE_kmod-oaf` 递归依赖；
  ② kconfig 把这条判为 broken 后不再传播 select，生成的 `.config` 里
  `CONFIG_PACKAGE_kmod-oaf` 就是 `is not set` —— **界面在、内核模块不在，功能必然残废**
  （2026-10-17 TEST 实证）；③ 就算装上，NSS 加速下流量不过 netfilter 钩子，功能本身也失效。
  `Packages.sh` 与 `JDCloud-noWiFi.config` 里都以注释形式保留，取消注释即可恢复。
- **写了 `=y` 的符号也可能被 defconfig 静默丢掉** —— 证据就是 `CONFIG_TARGET_ROOTFS_PARTSIZE`：
  它在 `Config-images.in` 里 `depends on USES_ROOTFS_PART || TARGET_ROOTFS_EXT4FS`，
  亚瑟是 EmmcImage，两个条件都不满足 → 符号不可见，写了不报错也不生效。
  所以「配置里写了」和「真的生效了」是两回事，**必须用 TEST 的诊断输出核对**。
- **别默认「界面包会带出主程序」**。OpenWrt 的 `DEPENDS` 在 Kconfig 里生成的是 `depends on`
  而不是 `select`，而 `depends on` 只保证下限（把你提到 `=m` 就算满足）。
  更要命的是有些界面包压根没写主程序依赖 —— `luci-app-easytier` 的 `LUCI_DEPENDS`
  只有 `+kmod-tun +luci-compat`，所以主程序 `easytier` 必须单独显式写 `=y`。
  **凡是「界面 + 主程序」结构的插件，两行都要写。**
