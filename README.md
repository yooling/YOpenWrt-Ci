# YOpenWRT-CI

自用 OpenWrt 云编译仓库，维护两台 IPQ6000 设备。骨架 fork 自 VIKINGYFY/OpenWRT-CI

## 产出矩阵

**2 种固件 × 2 条源码线 = 4 个产物**（2026-10-13 起只维护 noWiFi）：

| 配置               | 设备                          | WiFi | 硬件                               |
| ---------------- | --------------------------- | ---- | -------------------------------- |
| `JDCloud-noWiFi` | 京东云亚瑟 RE-SS-01 / AX1800 Pro | 无    | IPQ6000，硬改 1G RAM + 64G eMMC     |
| `ZNM2-noWiFi`    | 兆能 ZN-M2                    | 无    | IPQ6000，硬改512MB RAM + 128MB NAND |

> 曾经的第三份 `JDCloud-WiFi`（亚瑟带 WiFi）已于 2026-10-13 停用：配置留档在
> `Config/JDCloud-WiFi.config`（文件头有恢复三步说明），工作流 `JDCloud-WiFi.yml`
> 移至 `.trash-old/`。两台设备现在都当纯有线路由 / 主路由用。

**2 条工作流，一条工作流 = 一份设备配置**。源码线不写死在文件里，而是**运行时用  
`SOURCE` 下拉框手动选**，一次运行只出那一条线的固件。

| 工作流                  | 配置（写死）           | 运行时 `SOURCE` 可选项                   | 默认         |
| -------------------- | ---------------- | ---------------------------------- | ---------- |
| `JDCloud-noWiFi.yml` | `JDCloud-noWiFi` | `OWrt-NSS` / `OWrt-PPE` / `LibWrt` | `OWrt-NSS` |
| `ZNM2-noWiFi.yml`    | `ZNM2-noWiFi`    | `OWrt-NSS` / `OWrt-PPE` / `LibWrt` | `OWrt-NSS` |

> ★2026-10-13 事故驱动修改：两份 noWiFi 的默认源从 `OWrt-PPE` 改成 `OWrt-NSS`，**勿改回**。  
> 背景：两台设备各刷过一次「默认构建」的固件，症状一致 —— 开机一段时间后所有网口灯灭、  
> 不可达，软重启不恢复。共同点只剩「都用了本仓库的默认配置」= owrt 分支（全新 PPE/EDMA  
> 数据面，2026-10 上旬仍在密集修 idle-port 挂死类缺陷）。参考作者全走 NSS 成熟面。  
> 完整记录见下面「灭灯变砖事故」一节。

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

主机名按**源码线**区分（`OWrt` / `LibWrt`），IP 错开成 10.x / 20.x，  
这样两台路由插在同一张网里不撞 IP，进后台看主机名就知道刷的是哪条线。

辅助：`WRT-TEST.yml`（只出 `.config` 不编译）、`Auto-Clean.yml`、`Cache-Clean.yml`。

## 配置组织：一设备一配置，自包含清单

```
Config/
  GENERAL.config       共用基座（上游 VIKINGYFY 原版，不做本地增删）
  JDCloud-noWiFi.config 亚瑟无 WiFi：完整清单
  ZNM2-noWiFi.config    M2 无 WiFi：完整清单
  TEST.config           调试用，只出 .config
  JDCloud-WiFi.config   已停用留档（文件头有恢复说明），不被任何工作流引用
```

> 2026-10-13：配置文件后缀 `.txt` → `.config`（对齐 breeze303 / laipeng668 / ZqinKing  
> 三位参考作者，同时避开 `.txt` 被本地文件加密软件误拦的风险）。仓库内引用已全部同步  
> （workflows / Scripts / .gitattributes），CI 的 dos2unix 步骤也覆盖 `.config`。

### 两份 noWiFi 配置的差异对照

| 项目                                 | JDCloud-noWiFi       | ZNM2-noWiFi                           |
| ---------------------------------- | -------------------- | ------------------------------------- |
| ath11k / 无线固件                      | **显式 `=n` 关掉**       | **显式 `=n` 关掉**                        |
| Docker 全套                          | **`=m`**（按需 apk add） | **关**（512MB + NAND 跑不动）               |
| 代理栈                                | nikki + openclash  | **只用 nikki**（两者抢 7890 与防火墙规则）      |
| 网络设置向导（netwizard）                 | 开                    | 开（配网络的第一入口）                          |
| 首启网络向导（network_guide）              | 开（2026-10-13 新增）   | 开（2026-10-13 新增）                     |
| 首页汇总页（quickstart）                 | 开                    | **关**（128MB NAND 不值得多装一套前端）          |
| AdGuard Home                       | 开（`INCLUDE_binary=n`） | **关**（内存要跟 nikki 抢，DNS 功能也重叠）       |
| eMMC 健康监测                         | 开                    | **关**（M2 是 NAND、机器上没有 eMMC）         |
| btrfs / NVMe / ATA / smartmontools | 开                    | **关**                                 |
| samba4 / diskman / partexp         | 开                    | **关**                                 |
| 多 WAN（mwan3）                       | 无                    | **已移除**（源里没有这个包 + 用不到，整节删掉）         |
| zram-swap                          | 开                    | 开（512MB 刚需）                           |
| USB 控制器 / 存储 / 工具                | 开（还带 USB 网卡驱动）      | **关**（ZN-M2 没有 USB 口，装了也用不上）           |
| 4G 网卡模式切换（usb-modeswitch）        | **开**（配合上面那组 USB 网卡）  | 无（没有 USB 口）                          |
| 文件系统 ext4/f2fs/vfat/exfat          | 开                    | **关**                                 |
| 分区格式化工具（blkid/lsblk/fdisk/parted/e2fsprogs…） | 开                    | **关**（没有外接盘位，配套的也一起省掉）              |
| coremark / 小工具                     | 开                    | **关**（NAND 省空间）                       |
| DDNS（ddns-go）                     | 开                    | **关**（内网主路由用不到）                       |
| SSL 证书（acme 一整套）                  | **无**                | **无**（整套停用，源码 Makefile 里也写着）         |
| 主题                                 | argon                 | argon                                 |

> 已停用的 `JDCloud-WiFi.config`（亚瑟带 WiFi）不参与本对照，恢复方法见其文件头。  
> 文件系统与分区工具那两行是跟着 USB 一起走的：ZN-M2 既没有 USB 口也没有任何外接盘位，  
> 系统本身就跑在 NAND（ubifs）上，留着 ext4/f2fs/exfat 和那套分区工具只是白占内核体积与 NAND。  
> 亚瑟有 USB 口，这些东西全部保留在它自己那份配置里（GENERAL.config 里已下放，不会反向塞回 M2）。  
> ▲注意：ZNM2 那份里这些项写的是**显式 `=n`** 而不是注释掉 —— 它们大多在 target 的  
> `DEFAULT_PACKAGES` 里，注释掉等于用默认值、照样编进固件（踩过，详见下面 GENERAL 纪律段）。

### 插件取舍（2026-10-12 定，10-13 增补 network_guide）

对照 ZqinKing / VIKINGYFY / laipeng668 / breeze303 / darkrain88 五份配置逐项过了一遍，结论如下：

| 功能 | 包名 | 亚瑟 | M2 | 判断依据 |
| --- | --- | --- | --- | --- |
| 网络设置向导 | `luci-app-netwizard` | **`=y`** | **`=y`** | 拨号 / DHCP / 静态 IP / **旁路由** 一键切换。原来写 `=m` 等于刷完看不见（`=m` 不进固件），而"第一次配网络"恰恰最需要它。界面只有几十 KB |
| 首启网络向导 | `luci-app-wizard` | **`=y`** | **`=y`** | X-WRT 血统（x-wrt/com.x-wrt/luci-app-wizard，经 kenzok8/small-package 引入）。第一次开机自动跳出引导页带用户配网，进度记 `/etc/config/wizard`，配完不再出现。与 netwizard 分工：一个偏首次上手、一个偏日常切换。Makefile 依赖为空、默认配置为空，无后台行为 |
| 首页汇总页 | `quickstart` | **`=y`** | `=n` | ZqinKing 京东云固件的首页就是它。M2 的 128MB NAND 不值得为一套前端资源让路 |
| AdGuard Home | `luci-app-adguardhome` | **`=y`**（`INCLUDE_binary=n`） | `=n` | core 30–40MB、常驻 50–150MB。亚瑟 1G 内存扛得住；M2 要跟 nikki 抢内存，且 nikki 自带 DNS，功能重叠 |
| eMMC 健康 | `luci-app-emmc-health` | **`=y`** | `=n` | 读 eMMC 的 EXT_CSD。**M2 是 NAND、机器上没有 eMMC**，装了页面也是空的（ZqinKing 给 zn_m2 的配置里同样没有这项） |
| OAF 应用过滤 | `open-app-filter` | 不做 | 不做 | **与 NSS 硬件加速冲突** —— DPI 逐包匹配走慢路径、绕过 NSS 快转，千兆跑不满。laipeng668 的配置里明写着 `luci-app-oaf=n` |
| iStore 增强 | `luci-app-istorex` | 不做 | 不做 | iStore 生态整个围绕 opkg 建，而源码已迁 apk，兼容性存疑；且要联网拉全量元数据 |
| Docker | `docker` / `dockerd` / `luci-app-dockerman` | **`=m`** | `=n` | 亚瑟后续要跑容器。整组约 45–55MB，`=y` 会把固件撑大一倍；`=m` 只编包不进 rootfs，需要时从 Release 的差集包 `apk add`。第四节的 `kmod-br-netfilter` / `kmod-ipt-nat6` / `kmod-nf-conntrack-netlink` 与 cgroup 选项已一并打开 —— **cgroup 是内核编译开关，事后 apk add 装不回来，必须现在开** |

> ⏱ **AdGuard Home 会让编译变慢**：`adguardhome` 本体是 Go 写的（`DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle`），
> 编它要把 Go 工具链跑一遍，比普通 LuCI 插件耗时明显。ZqinKing 也是照样编的，属于可接受代价；
> 实在不想等就把 `luci-app-adguardhome` 那两行注释掉。
>
> ⚠️ **新增的四个源都不能走 feeds**：`quickstart` / `adguardhome` / `luci-app-wizard` 虽然都在
> kenzok8/small-package（即 smpackage feed）里，但 `feeds install -a` 时官方 feed 先占住包名、
> 官方同名包又被 WRT-CORE.yml 的「删官方同名包」删掉，包会从源码树里彻底消失 —— 那 119 个包
> 就是这么没的，`adguardhome` 正在名单里。所以这几个都改用 `Packages.sh` 的 `UPDATE_PACKAGE`
> 直接落到 `wrt/package/`（优先级高于 feeds，且 Custom Packages 步骤排在 feeds install 之后）。
> `luci-app-dockerman` 同理：smpackage 那份被 WRT-CORE.yml 删了、官方 luci feed 从来没有它。

### 主题为什么是 argon（2026-10-09 定）

`sorted by 占用 / 稳定性`：两者实际体积差不多 —— argon 的 ipk 实测 389KB，aurora 的
css(185KB) + 图片(122KB) + 字体(23KB) + 补丁(12KB) 约 350KB，**差别不在大小**，所以按下述两条定：

| | argon（留下） | aurora（去掉） |
| --- | --- | --- |
| 技术栈 | 传统 LuCI 模板 + 手写 CSS，对不上最多错位 | Vite + Tailwind 预编译 bundle，DOM 变了容易白屏 |
| 维护现状 | jerrykuku 一直在更新（2026-10 仍有提交，5.5k star） | 580 star 的新项目，2026-09 最后提交 |

主题由 `Scripts/Settings.sh` 按 workflow 的 `WRT_THEME` 注入；`luci-app-<主题>-config`（外观自定义页）
已停用 —— 主路由用不上，它还会往固件里塞壁纸素材。`luci-theme-aurora` / `luci-app-aurora-config`
在 GENERAL.config 里写成**显式 `=n`**（不是注释掉，理由同上）。

### 插件分三档：`=y` / `=m` / `=n`

每个设备配置的插件清单都按这个结构写：**8.1 刚需 `=y` → 8.2 冷门 `=m` → 8.3 不要 `=n`**。

冷门插件**用 `=m` 而不是删**，这是本项目最主要的精简手段。`=m` 表示「编译成 apk，但不打进固件」，  
这些包会被自动收进 `Packages-extra-*.tar.gz` 发布，用到时 `apk add` 装上 —— 既省了固件空间，  
又不用为加一个插件重编一遍固件，正对上「先精简，用着缺了再补」。

判定的依据是对本地 12 份针对 IPQ60xx / M2 / 亚瑟的参考配置做的频次统计：多位作者都带的  
（autoreboot 7 份、samba4 5 份、diskman/upnp 各 4 份）留 `=y`；零命中或只被一位作者用的  
（timecontrol、natmapt、wolultra、mini-diskmanager 等）降到 `=m`。  
netwizard 一度也按频次降到 `=m`，后又提回 `=y`（理由见上一节插件取舍：配网络的第一入口  
不能不进固件）。`=m` 为主的这套写法参考的是 **darkrain88**（已在本机亚瑟上刷机验证可用）  
—— 它的 GENERAL 里 openclash / partexp / samba4 / ddns-go / gecoosac / easytier / lucky 全是 `=m`。

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

**`Config/DepCheck-ignore.config` 是豁免清单，不是垃圾桶。** 准入标准只有一条硬的：
完整编译跑完、出了固件、相关功能在 manifest 里确实装上了，才允许写进去；
`mwan3` 那种会在 `package/install` 阶段炸掉的绝对不许放 —— 它当时炸的就是
`ERROR: unable to select packages: mwan3 (no such package)`。清单里每条都写了实证依据和日期。

### GENERAL.config 的纪律（踩过坑，别改回去）

**GENERAL 只放「两份设备配置一致同意」的包。只要有一份要 `=n` 或 `=m`，就写进那一份自己的配置。**

原因在加载顺序：`.config` 是 WRT-CORE.yml 里两次 `cat` 拼出来的（Packages.sh 只负责拉第三方  
包源、不生成 .config），顺序是「机型配置 → GENERAL.config」，GENERAL **在后加载**，  
同一个 `CONFIG_PACKAGE_*` key 后出现的覆盖先出现的 —— 于是 GENERAL 里的 `=y` 会把机型层写的  
`=n` 翻回 `=y`。

实际踩到的后果：ZNM2-noWiFi.config 里明明白白写了 gecoosac / partexp / samba4 / statistics /  
wolultra 五个 `=n`（M2 是 128MB NAND，刻意做减法），**一个都没生效**，照样躺进固件；  
配置看着只装 7 个 luci 包，实际装了 20 个。JDCloud 两份因为本来就都要这些包，看着「没问题」，  
所以这个 bug 只在存储最紧的 M2 上暴露出来。修完之后各份配置都不再有任何反向覆盖。

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
| 1 | 机型配置 | `Config/<配置>.config` | WRT-CORE.yml |
| 2 | 通用基座 | `Config/GENERAL.config` | WRT-CORE.yml（在后 → 会盖掉 1 的 `=n`）|
| 3 | 脚本注入 | luci / 主题 / ath11k 内存档位 / NSS 版本 / `$WRT_PACKAGE` | Settings.sh |
| 4 | 通用覆盖 | `Config/PRIVATE.config` | Settings.sh 末尾 |
| 5 | 特定覆盖 | `Config/PRIVATE-<配置>.config` | Settings.sh 末尾 |
| 6 | 依赖求解 | `make defconfig` | — |

第 4、5 两层是**最终裁决层**：某台设备要例外时建个 `Config/PRIVATE-ZNM2-noWiFi.config` 写一行  
`CONFIG_PACKAGE_xxx=n` 就行，一定压得住前面所有层。顺序是**通用在前、特定在后** —— 越具体越优先，  
跟 CSS 特异性、git config 本地>全局一个道理；反过来通用会闷掉特定，那这一层就白加了。  
两个文件都不存在时整段跳过，零成本。**当前仓库里就没有这两个文件 —— 这是有意为之**：  
两份 noWiFi 配置与 GENERAL 的冲突已经归零（该下放的下放了），没有需要裁决的分歧，建空文件纯属摆设。

> **PRIVATE 是逃生舱，不是第 4 份配置文件。** 常规调整一律改 `Config/<配置>.config` 正本；  
> 只有在「想改的值与 GENERAL 冲突、**且** GENERAL 里那个 `=y` 还得留给别的设备」时才建 PRIVATE。  
> 否则会出现「两份文件都写着同一个包、哪个是真的」的困惑 —— 那正是我们要避免的。  
> 真到了那一步，一行命令的事：  
> `printf 'CONFIG_PACKAGE_xxx=n\n' > Config/PRIVATE-ZNM2-noWiFi.config`

> 命名用 `PRIVATE` 而不是 `OVERRIDE`：这是 VIKINGYFY 骨架原生就有的名字（uiYzzi 也用  
> `PRIVATE-<机型>.config`），顺势扩展成「通用 + 特定」两级，比另起一套 OVERRIDE 少一个概念，  
> 同步上游时冲突也少。语义上它其实描述的是「归属」不是「优先级」，这点靠上面这张表补。

> 第 6 层严格说不是覆盖，但它会补依赖、仲裁互斥，能把某些 `=n` 悄悄拉回 `=y`，所以列在这儿  
> 提醒自己它不是终点 —— 真想知道某个包最终进没进固件，跑一次 WRT-TEST 看 Release 里的  
> `Config-*.config`，那是 defconfig 收敛后的答案。

## 用法

1. fork → **Settings → Actions → General → Workflow permissions** 设为 **Read and write**。
2. 改完配置先跑 **Actions → WRT-TEST → Run workflow**：选 `CONFIG` + 选 `SOURCE`，  
   几分钟出结果，验证能不能过 `defconfig`。
3. 正式编译跑对应的 `JDCloud-noWiFi` / `ZNM2-noWiFi`，**记得选 `SOURCE`**，产物在 Releases。  
   两条都默认 `OWrt-NSS`（成熟 NSS 数据面）；要追新数据面才显式选 `OWrt-PPE`，并自行承担  
   不稳定性 —— 改默认值的缘由见下面「灭灯变砖事故」一节。

### Release 里除了固件还有什么

`Packages-extra-*.tar.gz` 是**编出来了但没打进固件**的安装包（即配置里写成 `=m` 的那些），  
需要时解压后 `apk add *.apk` 自己装。

> `bin/packages/` 下 `=y` 的包也会产出 `.apk`，但它们已经在固件里了 —— 以前连这些一起发，  
> 一次 Release 能散出 70 个 apk。现在拿 `*.manifest`（固件实际装了什么）做一次差集，  
> 只发真正没装进去的，并打成单个压缩包。参考做法：breeze303 / ZqinKing 都是同 Release  
> 内打包（`Packages.tar.gz` / `kmods_*.tar.gz`），laipeng668 另开一个 packages 仓库按插件  
> 逐个发布；我们只有两台设备、不需要跨机型复用，就跟着前一种走。

## 灭灯变砖事故与默认源码线（2026-10-13）

**症状**：亚瑟与 M2 各刷过一次本仓库「默认构建」的固件，开机一段时间后所有网口灯灭、  
设备不可达，软重启不恢复，彻底重刷才恢复。换刷其他作者的固件无此状况。

**排查结论：不是源码问题，是配置问题**。两台设备当时跑的是不同源码线（一条 LibWrt、  
一条 owrt），共同点只剩「都用了本仓库的默认配置」—— 而两份 noWiFi 工作流的默认源  
都是 `OWrt-PPE`（= `VIKINGYFY/immortalwrt @ owrt`，全新 PPE/EDMA 数据面，2026-10 上旬  
仍在密集修补 idle-port egress wedge、UNIPHY0 SGMII 一类缺陷，尚在观察期）。其「软复位  
不清交换机芯片状态、重刷/断电才恢复」的表现与 idle-port 挂死类缺陷吻合。breeze303 /  
laipeng668 / ZqinKing（含 zn_m2 配置）全部走 main / NSS 成熟面，故选 NSS 作默认。

**已落的修改**：

1. 两份 noWiFi 工作流默认源 `OWrt-PPE` → `OWrt-NSS`；`OWrt-PPE` 仍保留下拉选项，  
   追新数据面者显式自选、自担风险。
2. `Scripts/Settings.sh` 的 DTS 手术改为**按目录存在性自动探测 + nowifi dtsi 存在性守卫**：  
   原来写死 `target/linux/qualcommax/dts/`，在 LibWrt 线（没有该目录、文件全在  
   `files/arch/arm64/boot/dts/qcom/`）上 `find` 静默无操作，Q6 内存缩减与亚瑟 memory-mode  
   调整全部落空；且若无守卫，`sed` 会把 LibWrt 的 `#include "ipq6018.dtsi"` 改成不存在  
   的文件名，直接导致 DTS 编译失败。

**仍未取得**：设备侧崩溃日志 / 串口 UART 输出（重刷后证据已丢）；两台出故障前的固件 tag。  
若日后再遇相同症状：先接串口抓 log，并记录当时的 `SOURCE` 选项与 Release tag。

### 10-13 第二轮：换了 NSS 源还不够，补上配置侧的四处缺口

上一节把默认源从 PPE 换成 NSS，但「开机正常 → 跑一阵子整机不动 → 灯全灭 → 重启无效」
在 IPQ60xx + NSS 上还有几个已知诱因。逐个对账 breeze303 / laipeng668 / ZqinKing 的代码后发现
**我们这些一处都没做**，现全部补齐：

| # | 缺口 | 三位参考作者的做法 | 本仓库修复位置 |
|---|---|---|---|
| 1 | **京东云 LED 没人管** —— 亚瑟的指示灯不是普通 GPIO LED，靠 `athena_led` 常驻服务定时下发状态；没有它，灯的「主人」缺失，表现为开机亮、跑一阵子灭、重启也不亮 | breeze303 `libwrt.sh` 第 1 行就删掉 emortal 版再 clone NONGFAH 版；laipeng668 `Roc-script.sh` 同源；ZqinKing 京东云配置 `=m` 并按设备挑出 | `Packages.sh` 恢复拉包 + `JDCloud-noWiFi.config` 设 `=y` |
| 2 | **NSS pbuf 自动扩缩** —— 开着 `auto_scale` 时 NSS 按流量反复扩缩包缓冲池，长时间跑容易耗尽池子或内存；数据面一崩整机就停在原地 | ZqinKing `update_nss_pbuf_performance()`：`auto_scale` 关掉、`scaling_governor` 由 `performance` 改 `schedutil` | `Settings.sh` 高通段 |
| 3 | **NSS 启动顺序 + 模块裁剪** —— 驱动未就绪网络就起来了；且两份都是 noWiFi 配置，ath11k 整条已关，NSS 却仍带着 WiFi 卸载与 mesh 管理（等于驱动在等一个不存在的硬件） | ZqinKing `update_script_priority()`（drv `START=88` / pbuf `89`）+ `remove_something_nss_kmod()`（删 crypto、wifi-meshmgr、gre、map-t、mirror 等） | `Settings.sh` 高通段 |
| 4 | **没有兜底复位** —— 内核真卡死后没有任何东西把它拉回来，于是表现为「重启无效」 | 三家都没单独做，属本仓库加的保险 | `GENERAL.config` 开 `CONFIG_PACKAGE_watchdog=y` |

附带两处：

- 照 ZqinKing `set_custom_task()` 注入每天一次 `drop_caches`，缓解长时间运行的缓存堆积。
- **M2 关掉 `zram-swap`**：zram 拿内存当交换盘，不增加可用内存，512MB 机器上压力大了容易
  OOM 连环杀进程。对账结果 —— ZqinKing 的 `zn_m2` 配置**完全没有** zram，亚瑟那份也只 `=m`；
  laipeng668 是 `=y`。M2 先关掉做对照（亚瑟 1G 保留 `=y`）。

> **这些是「降低故障概率 + 提升故障后可恢复性」，不等于已锁定唯一真凶。**
> 仍建议下次遇到时先接串口抓一次崩溃日志（见上节「仍未取得」）。

### 本轮产物收敛：先只出两份 noWiFi

按 2026-10-13 的决定，本阶段只维护 `JDCloud-noWiFi` 与 `ZNM2-noWiFi` 两份配置
（亚瑟 / M2 各一，均无 WiFi）。`JDCloud-WiFi.config` 已移入 `.trash-old/` 留档，需要时整份搬回
`Config/` 即可，同时把 `.trash-old/JDCloud-WiFi.yml` 也搬回 `.github/workflows/`。
两条工作流**保留下拉选择源仓库**（`SOURCE`：`OWrt-NSS` / `LibWrt` 等），用法不变。

## 目录

```
.github/workflows/  WRT-CORE.yml 是唯一干活的，其余全是薄壳
Config/             GENERAL.config + 两份 noWiFi 设备配置 + TEST.config
                    DepCheck-ignore.config 依赖预检的豁免清单（准入标准很严，见文件头）
                    （JDCloud-WiFi.config 已移入 .trash-old/，恢复方法见上一节）
Scripts/            Packages.sh 拉包 / Handles.sh 修 feeds / Settings.sh 改系统设置
                    DepCheck.sh 依赖预检（defconfig 之后跑，只告警不阻断）
                    USB-WAN.sh 暂未启用（见 Handles.sh 注释）
.trash-old/         停用/历史文件留档（JDCloud-WiFi.yml 与历次重构的旧配置都在这里）
USB-WAN.md          USB 网卡 WAN 玩法，需要时按它恢复
```
