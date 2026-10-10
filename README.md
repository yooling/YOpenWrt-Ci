# YOpenWRT-CI

自用 OpenWrt 云编译仓库，维护两台 IPQ6000 设备。骨架 fork 自 VIKINGYFY/OpenWRT-CI

## 产出矩阵

**3 种固件 × 2 条源码线 = 6 个产物**：

| 配置               | 设备                          | WiFi | 硬件                               |
| ---------------- | --------------------------- | ---- | -------------------------------- |
| `JDCloud-WiFi`   | 京东云亚瑟 RE-SS-01 / AX1800 Pro | 有    | IPQ6000，硬改 1G RAM + 64G eMMC     |
| `JDCloud-noWiFi` | 京东云亚瑟 RE-SS-01 / AX1800 Pro | 无    | 同上（当纯有线路由 / 外接 AP 用）             |
| `ZNM2-noWiFi`    | 兆能 ZN-M2                    | 无    | IPQ6000，硬改512MB RAM + 128MB NAND |

**3 条工作流，一条工作流 = 一份设备配置**。源码线不写死在文件里，而是**运行时用  
`SOURCE` 下拉框手动选**，一次运行只出那一条线的固件。

| 工作流                  | 配置（写死）           | 运行时 `SOURCE` 可选项                   | 默认         |
| -------------------- | ---------------- | ---------------------------------- | ---------- |
| `JDCloud-WiFi.yml`   | `JDCloud-WiFi`   | `OWrt-NSS` / `LibWrt`              | `OWrt-NSS` |
| `JDCloud-noWiFi.yml` | `JDCloud-noWiFi` | `OWrt-PPE` / `OWrt-NSS` / `LibWrt` | `OWrt-PPE` |
| `ZNM2-noWiFi.yml`    | `ZNM2-noWiFi`    | `OWrt-PPE` / `OWrt-NSS` / `LibWrt` | `OWrt-PPE` |

选了 `SOURCE` 之后，**仓库 / 分支 / 主机名 / 管理 IP 全部自动带出**，不用再手填：

| `SOURCE`   | 仓库 @ 分支                          | 主机名      | 管理 IP          | 内核                          |
| ---------- | -------------------------------- | -------- | -------------- | --------------------------- |
| `OWrt-NSS` | `VIKINGYFY/immortalwrt` @ `main` | `OWrt`   | `192.168.10.1` | 6.18 满血 NSS，带 WiFi + 无 WiFi |
| `OWrt-PPE` | `VIKINGYFY/immortalwrt` @ `owrt` | `OWrt`   | `192.168.10.1` | 6.18 PPE 加速，**不支持 WiFi**    |
| `LibWrt`   | `LiBwrt/LibWrt` @ `25.12-nss`    | `LibWrt` | `192.168.20.1` | 6.12 满血 NSS + WiFi 卸载       |

> **分支为什么不单独给一个输入框？** GitHub 的 `workflow_dispatch` 表单**不支持联动** ——  
> 选了源码不会让分支框自动带出对应值；而空输入框会被浏览器 autofill 成旧默认值 `main`，  
> 结果是「选了 PPE 线却拉到 main 分支」。所以把分支并进 `SOURCE` 这一个下拉里，  
> 一个选项同时决定仓库 + 分支，没有可以填错的地方。  
> 带 WiFi 的工作流不列 `OWrt-PPE`（owrt 分支本来就不支持 WiFi）。

主机名按**源码线**区分（`OWrt` / `LibWrt`），IP 错开成 10.x / 20.x，  
这样两台路由插在同一张网里不撞 IP，进后台看主机名就知道刷的是哪条线。

辅助：`WRT-TEST.yml`（只出 `.config` 不编译）、`Auto-Clean.yml`、`Cache-Clean.yml`。

## 配置组织：一设备一配置，自包含清单

```
Config/
  GENERAL.txt        共用基座（上游 VIKINGYFY 原版，不做本地增删）
  JDCloud-WiFi.txt   亚瑟带 WiFi：完整清单
  JDCloud-noWiFi.txt 亚瑟无 WiFi：完整清单
  ZNM2-noWiFi.txt    M2 无 WiFi：完整清单
  TEST.txt           调试用，只出 .config
```

### 三份配置的差异对照

| 项目                                 | JDCloud-WiFi | JDCloud-noWiFi       | ZNM2-noWiFi                           |
| ---------------------------------- | ------------ | -------------------- | ------------------------------------- |
| ath11k / 无线固件                      | 开（机型默认带）     | **显式 `=n` 关掉**       | **显式 `=n` 关掉**                        |
| Docker 全套                          | 关            | **`=m`**（按需 apk add） | **关**（512MB + NAND 跑不动）               |
| btrfs / NVMe / ATA / smartmontools | 开            | 开                    | **关**                                 |
| samba4 / diskman / partexp         | 开            | 开                    | **关**                                 |
| 多 WAN（mwan3）                       | 无            | 无                    | **已移除**（源里没有这个包 + 用不到，整节删掉）         |
| zram-swap                          | 开            | 开                    | 开（512MB 刚需）                           |
| USB 控制器 / 存储 / 工具                | 开            | 开（还带 USB 网卡驱动）      | **关**（ZN-M2 没有 USB 口，装了也用不上）           |
| 4G 网卡模式切换（usb-modeswitch）        | 关（网卡驱动没开，切了也没用） | **开**（配合上面那组 USB 网卡）  | 无（没有 USB 口）                          |
| 文件系统 ext4/f2fs/vfat/exfat          | 开            | 开                    | **关**                                 |
| 分区格式化工具（blkid/lsblk/fdisk/parted/e2fsprogs…） | 开            | 开                    | **关**（没有外接盘位，配套的也一起省掉）              |
| coremark / 小工具                     | 开            | 开                    | **关**（NAND 省空间）                       |
| DDNS（ddns-go）                     | 开            | 开                    | **关**（内网主路由用不到）                       |
| SSL 证书（acme 一整套）                  | **无**        | **无**                | **无**（整套停用，源码 Makefile 里也写着）         |
| 主题                                 | argon         | argon                 | argon                                 |

> 文件系统与分区工具那两行是跟着 USB 一起走的：ZN-M2 既没有 USB 口也没有任何外接盘位，  
> 系统本身就跑在 NAND（ubifs）上，留着 ext4/f2fs/exfat 和那套分区工具只是白占内核体积与 NAND。  
> 亚瑟有 USB 口，这些东西全部保留在它自己那两份配置里（GENERAL.txt 里已下放，不会反向塞回 M2）。  
> ▲注意：ZNM2 那份里这些项写的是**显式 `=n`** 而不是注释掉 —— 它们大多在 target 的  
> `DEFAULT_PACKAGES` 里，注释掉等于用默认值、照样编进固件（踩过，详见下面 GENERAL 纪律段）。

### 主题为什么是 argon（2026-10-09 定）

`sorted by 占用 / 稳定性`：两者实际体积差不多 —— argon 的 ipk 实测 389KB，aurora 的
css(185KB) + 图片(122KB) + 字体(23KB) + 补丁(12KB) 约 350KB，**差别不在大小**，所以按下述两条定：

| | argon（留下） | aurora（去掉） |
| --- | --- | --- |
| 技术栈 | 传统 LuCI 模板 + 手写 CSS，对不上最多错位 | Vite + Tailwind 预编译 bundle，DOM 变了容易白屏 |
| 维护现状 | jerrykuku 一直在更新（2026-10 仍有提交，5.5k star） | 580 star 的新项目，2026-09 最后提交 |

主题由 `Scripts/Settings.sh` 按 workflow 的 `WRT_THEME` 注入；`luci-app-<主题>-config`（外观自定义页）
已停用 —— 主路由用不上，它还会往固件里塞壁纸素材。`luci-theme-aurora` / `luci-app-aurora-config`
在 GENERAL.txt 里写成**显式 `=n`**（不是注释掉，理由同上）。

### 插件分三档：`=y` / `=m` / `=n`

每个设备配置的插件清单都按这个结构写：**8.1 刚需 `=y` → 8.2 冷门 `=m` → 8.3 不要 `=n`**。

冷门插件**用 `=m` 而不是删**，这是本项目最主要的精简手段。`=m` 表示「编译成 apk，但不打进固件」，  
这些包会被自动收进 `Packages-extra-*.tar.gz` 发布，用到时 `apk add` 装上 —— 既省了固件空间，  
又不用为加一个插件重编一遍固件，正对上「先精简，用着缺了再补」。

判定的依据是对本地 12 份针对 IPQ60xx / M2 / 亚瑟的参考配置做的频次统计：多位作者都带的  
（autoreboot 7 份、samba4 5 份、diskman/upnp 各 4 份）留 `=y`；零命中或只被一位作者用的  
（netwizard、timecontrol、natmapt、wolultra、mini-diskmanager 等）降到 `=m`。  
`=m` 为主的这套写法参考的是 **darkrain88**（已在本机亚瑟上刷机验证可用）—— 它的 GENERAL 里  
openclash / partexp / samba4 / ddns-go / gecoosac / easytier / lucky 全是 `=m`。

> ⚠️ **`=m` 的包也会被 DepCheck 检查依赖**。源码迁移 apk 之后缺依赖是致命错误（不是警告），  
> `=m` 的包缺依赖一样会在 `package/install` 阶段炸掉整个编译。加 `=m` 之前先跑一次 WRT-TEST。

### 依赖预检（DepCheck）与它的误报

`Scripts/DepCheck.sh` 在 `make defconfig` 之后跑，提前把 apk 阶段才会暴露的「依赖包不存在」列出来。
它只告警、永不阻断（退出码恒为 0）—— 误报毁掉一次完整编译的代价远高于漏报。

已经修掉的三类误报（都不是配置的问题，别去改 Config）：

| 报错长这样 | 真实原因 | 处理 |
| ---------- | -------- | ---- |
| `xxx -> NSS_DRV_IPV6_ENABLE` | 那是 Kconfig 配置开关，不是包名 | 全大写 + 下划线的 token 直接跳过 |
| `apk-openssl -> wget-any` | `wget-any` 是**虚拟包**，OpenWrt 写成 `Provides: @wget-any`（带 `@`），依赖方写成 `+wget-any`（不带 `@`），两边对不上 | `@name` 额外登记一份 `name` |
| `luci-app-acme -> acme` | 源里确实没有 `acme` 这个空壳 meta 包，但**编译验证过无害** | 见下面的豁免清单 |

最后一类的实证：26.10.09 那份 ZNM2 固件的 manifest 里 `acme-acmesh` / `acme-acmesh-dnsapi` /
`acme-common` / `luci-app-acme` / `luci-i18n-acme-zh-cn` 五项全在，编译正常跑完 —— 证书功能完整，
缺的只是一个 0.8KB 的 meta 包（功能本体是 `acme-acmesh` + `acme-common`）。
`CONFIG_PACKAGE_acme=y` 那行已注释停用，跟当初 mwan3 一个性质。

**`Config/DepCheck-ignore.txt` 是豁免清单，不是垃圾桶。** 准入标准只有一条硬的：
完整编译跑完、出了固件、相关功能在 manifest 里确实装上了，才允许写进去；
`mwan3` 那种会在 `package/install` 阶段炸掉的绝对不许放 —— 它当时炸的就是
`ERROR: unable to select packages: mwan3 (no such package)`。清单里每条都写了实证依据和日期。

### GENERAL.txt 的纪律（踩过坑，别改回去）

**GENERAL 只放「三份设备配置一致同意」的包。只要有一份要 `=n` 或 `=m`，就写进那一份自己的配置。**

原因在加载顺序：`.config` 是 WRT-CORE.yml 里两次 `cat` 拼出来的（Packages.sh 只负责拉第三方  
包源、不生成 .config），顺序是「机型配置 → GENERAL.txt」，GENERAL **在后加载**，  
同一个 `CONFIG_PACKAGE_*` key 后出现的覆盖先出现的 —— 于是 GENERAL 里的 `=y` 会把机型层写的  
`=n` 翻回 `=y`。

实际踩到的后果：ZNM2-noWiFi.txt 里明明白白写了 gecoosac / partexp / samba4 / statistics /  
wolultra 五个 `=n`（M2 是 128MB NAND，刻意做减法），**一个都没生效**，照样躺进固件；  
配置看着只装 7 个 luci 包，实际装了 20 个。JDCloud 两份因为本来就都要这些包，看着「没问题」，  
所以这个 bug 只在存储最紧的 M2 上暴露出来。修完之后三份配置都不再有任何反向覆盖。

**注释纪律靠不住（这个坑已经踩了两次），所以加了代码级防线**：`Scripts/Settings.sh` 会在  
`make defconfig` 之前扫描「机型层与 GENERAL 都写了、但取值不同」的 key，一旦有就打  
`::error::` 列出每个 key 的取值对照并**中断编译**。想保留冲突就在 PRIVATE 层显式写值（见下），  
那条会降级成 `::notice::` 放行。

> ⚠️ **把配置行注释掉 ≠ 关掉这个包**（第三类静默偏差，2026-10-09 两版固件对比实证）
>
> `target/linux/qualcommax/Makefile` 的 `DEFAULT_PACKAGES` 自带一整套：
> `automount` `e2fsprogs` `f2fs-tools` `kmod-fs-ext4` `kmod-fs-f2fs` `kmod-usb3`
> `kmod-usb-dwc3` `kmod-usb-dwc3-qcom` `kmod-usb-serial-qualcomm` …
> （`luci` `cpufreq` `autocore` `uboot-envtools` 也在里面）。
> 机型配置里把行**注释掉** = 这一行不存在 = 用 target 的默认值，包照样进固件。
>
> 实证：26.10.09 两版 ZNM2 固件的 manifest 对比 —— 注释掉的 `kmod-usb3` / `kmod-fs-ext4` /
> `automount` / `e2fsprogs` 一个都没少；而**不在** `DEFAULT_PACKAGES` 里的 `blkid` / `fdisk` /
> `parted` / `exfat-fsck` / `exfat-mkfs` / `sfdisk` 确实消失了（连带 `libfdisk1` /
> `libmount1` / `libparted` / `musl-fts` 也没了）。
>
> **想真正去掉，唯一办法是显式写 `=n`。** ZNM2 那份配置里那一整批就是这么写的。

### 完整加载链（越靠后优先级越高）

| # | 层 | 文件 | 谁追加 |
| - | ---- | ---- | ---- |
| 1 | 机型配置 | `Config/<配置>.txt` | WRT-CORE.yml |
| 2 | 通用基座 | `Config/GENERAL.txt` | WRT-CORE.yml（在后 → 会盖掉 1 的 `=n`）|
| 3 | 脚本注入 | luci / 主题 / ath11k 内存档位 / NSS 版本 / `$WRT_PACKAGE` | Settings.sh |
| 4 | 通用覆盖 | `Config/PRIVATE.txt` | Settings.sh 末尾 |
| 5 | 特定覆盖 | `Config/PRIVATE-<配置>.txt` | Settings.sh 末尾 |
| 6 | 依赖求解 | `make defconfig` | — |

第 4、5 两层是**最终裁决层**：某台设备要例外时建个 `Config/PRIVATE-ZNM2-noWiFi.txt` 写一行  
`CONFIG_PACKAGE_xxx=n` 就行，一定压得住前面所有层。顺序是**通用在前、特定在后** —— 越具体越优先，  
跟 CSS 特异性、git config 本地>全局一个道理；反过来通用会闷掉特定，那这一层就白加了。  
两个文件都不存在时整段跳过，零成本。**当前仓库里就没有这两个文件 —— 这是有意为之**：  
三份配置与 GENERAL 的冲突已经归零（该下放的下放了），没有需要裁决的分歧，建空文件纯属摆设。

> **PRIVATE 是逃生舱，不是第 4 份配置文件。** 常规调整一律改 `Config/<配置>.txt` 正本；  
> 只有在「想改的值与 GENERAL 冲突、**且** GENERAL 里那个 `=y` 还得留给别的设备」时才建 PRIVATE。  
> 否则会出现「两份文件都写着同一个包、哪个是真的」的困惑 —— 那正是我们要避免的。  
> 真到了那一步，一行命令的事：  
> `printf 'CONFIG_PACKAGE_xxx=n\n' > Config/PRIVATE-ZNM2-noWiFi.txt`

> 命名用 `PRIVATE` 而不是 `OVERRIDE`：这是 VIKINGYFY 骨架原生就有的名字（uiYzzi 也用  
> `PRIVATE-<机型>.txt`），顺势扩展成「通用 + 特定」两级，比另起一套 OVERRIDE 少一个概念，  
> 同步上游时冲突也少。语义上它其实描述的是「归属」不是「优先级」，这点靠上面这张表补。

> 第 6 层严格说不是覆盖，但它会补依赖、仲裁互斥，能把某些 `=n` 悄悄拉回 `=y`，所以列在这儿  
> 提醒自己它不是终点 —— 真想知道某个包最终进没进固件，跑一次 WRT-TEST 看 Release 里的  
> `Config-*.txt`，那是 defconfig 收敛后的答案。

## 用法

1. fork → **Settings → Actions → General → Workflow permissions** 设为 **Read and write**。
2. 改完配置先跑 **Actions → WRT-TEST → Run workflow**：选 `CONFIG` + 选 `SOURCE`，  
   几分钟出结果，验证能不能过 `defconfig`。
3. 正式编译跑对应的 `JDCloud-*` / `ZNM2-*`，**记得选 `SOURCE`**，产物在 Releases。  
   带 WiFi 默认 `OWrt-NSS`；两份 noWiFi 默认 `OWrt-PPE`（owrt 分支，PPE 加速）。

### Release 里除了固件还有什么

`Packages-extra-*.tar.gz` 是**编出来了但没打进固件**的安装包（即配置里写成 `=m` 的那些），  
需要时解压后 `apk add *.apk` 自己装。

> `bin/packages/` 下 `=y` 的包也会产出 `.apk`，但它们已经在固件里了 —— 以前连这些一起发，  
> 一次 Release 能散出 70 个 apk。现在拿 `*.manifest`（固件实际装了什么）做一次差集，  
> 只发真正没装进去的，并打成单个压缩包。参考做法：breeze303 / ZqinKing 都是同 Release  
> 内打包（`Packages.tar.gz` / `kmods_*.tar.gz`），laipeng668 另开一个 packages 仓库按插件  
> 逐个发布；我们只有两台设备、不需要跨机型复用，就跟着前一种走。

## 目录

```
.github/workflows/  WRT-CORE.yml 是唯一干活的，其余全是薄壳
Config/             GENERAL.txt + 三份设备配置 + TEST.txt
                    DepCheck-ignore.txt 依赖预检的豁免清单（准入标准很严，见文件头）
Scripts/            Packages.sh 拉包 / Handles.sh 修 feeds / Settings.sh 改系统设置
                    DepCheck.sh 依赖预检（defconfig 之后跑，只告警不阻断）
                    USB-WAN.sh 暂未启用（见 Handles.sh 注释）
USB-WAN.md          USB 网卡 WAN 玩法，需要时按它恢复
```
