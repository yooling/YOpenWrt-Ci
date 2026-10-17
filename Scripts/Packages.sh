#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#安装和更新软件包
UPDATE_PACKAGE() {
	local PKG_NAME=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	local PKG_SPECIAL=$4
	local PKG_LIST=("$PKG_NAME" $5)  # 第5个参数为自定义名称列表
	local REPO_NAME=${PKG_REPO#*/}
	local REPO_PATH="./package/$REPO_NAME"

	echo " "

	# 删除本地可能存在的不同名称的软件包
	for NAME in "${PKG_LIST[@]}"; do
		# 查找匹配的目录
		echo "Search directory: $NAME"
		local FOUND_DIRS=$(find ./feeds/luci/ ./feeds/packages/ -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null)

		# 删除找到的目录
		if [ -n "$FOUND_DIRS" ]; then
			while read -r DIR; do
				rm -rf "$DIR"
				echo "Delete directory: $DIR"
			done <<< "$FOUND_DIRS"
		else
			echo "Not fonud directory: $NAME"
		fi
	done

	# 克隆 GitHub 仓库
	git clone --depth=1 --single-branch --branch $PKG_BRANCH "https://github.com/$PKG_REPO.git" $REPO_PATH

	# 处理克隆的仓库
	if [[ "$PKG_SPECIAL" == "pkg" ]]; then
		find $REPO_PATH/*/ -maxdepth 3 -type d -iname "*$PKG_NAME*" -prune -exec cp -rf {} ./package \;
		rm -rf $REPO_PATH
	fi
}

# 调用示例
# UPDATE_PACKAGE "OpenAppFilter" "destan19/OpenAppFilter" "master" "" "custom_name1 custom_name2"
# UPDATE_PACKAGE "open-app-filter" "destan19/OpenAppFilter" "master" "" "luci-app-appfilter oaf" 这样会把原有的open-app-filter，luci-app-appfilter，oaf相关组件删除，不会出现coremark错误。

# UPDATE_PACKAGE "包名" "项目地址" "项目分支" "pkg，可选，从大杂烩中单独提取包名插件"
UPDATE_PACKAGE "argon" "sbwml/luci-theme-argon" "openwrt-25.12"
UPDATE_PACKAGE "aurora" "eamonxg/luci-theme-aurora" "master"
UPDATE_PACKAGE "aurora-config" "eamonxg/luci-app-aurora-config" "master"
UPDATE_PACKAGE "fluent" "LazuliKao/luci-theme-fluent" "main"
UPDATE_PACKAGE "footstrap" "VizzleTF/luci-theme-footstrap" "main"
UPDATE_PACKAGE "kucat" "sirpdboy/luci-theme-kucat" "master"
UPDATE_PACKAGE "kucat-config" "sirpdboy/luci-app-kucat-config" "master"
UPDATE_PACKAGE "shadcn" "eamonxg/luci-theme-shadcn" "main"

UPDATE_PACKAGE "momo" "nikkinikki-org/OpenWrt-momo" "main"
UPDATE_PACKAGE "nikki" "nikkinikki-org/OpenWrt-nikki" "main"
UPDATE_PACKAGE "openclash" "vernesong/OpenClash" "dev" "pkg"
UPDATE_PACKAGE "passwall" "Openwrt-Passwall/openwrt-passwall" "main" "pkg"
UPDATE_PACKAGE "passwall2" "Openwrt-Passwall/openwrt-passwall2" "main" "pkg"

UPDATE_PACKAGE "diskmanager" "4IceG/luci-app-mini-diskmanager" "main"
UPDATE_PACKAGE "easytier" "EasyTier/luci-app-easytier" "main"
UPDATE_PACKAGE "qmodem" "FUjr/QModem" "main"
UPDATE_PACKAGE "viking" "VIKINGYFY/packages" "main" "" "axonhub gecoosac sing-box luci-app-homeproxy luci-app-timewol luci-app-wolplus luci-app-wolultra"
UPDATE_PACKAGE "vnt" "lmq8267/luci-app-vnt" "main"

UPDATE_PACKAGE "diskman" "sbwml/luci-app-diskman" "main"
UPDATE_PACKAGE "mosdns" "sbwml/luci-app-mosdns" "v5" "" "v2dat"
UPDATE_PACKAGE "openlist2" "sbwml/luci-app-openlist2" "main"
UPDATE_PACKAGE "qbittorrent" "sbwml/luci-app-qbittorrent" "master" "" "qt6base qt6tools rblibtorrent"
UPDATE_PACKAGE "quickfile" "sbwml/luci-app-quickfile" "main"

UPDATE_PACKAGE "ddns-go" "sirpdboy/luci-app-ddns-go" "main"
UPDATE_PACKAGE "netspeedtest" "sirpdboy/netspeedtest" "main" "" "homebox ookla-speedtest"
#netwizard（sirpdboy）：已换成 NetWiz（huchd0）—— 刷入后确认要的是后者，详见下面那段。
#UPDATE_PACKAGE "netwizard" "sirpdboy/luci-app-netwizard" "main"
UPDATE_PACKAGE "partexp" "sirpdboy/luci-app-partexp" "main"
UPDATE_PACKAGE "timecontrol" "sirpdboy/luci-app-timecontrol" "main"

#======================= NetWiz（huchd0/luci-app-netwiz）=======================
#网络设置向导 —— 就是「NetWiz」，不是 sirpdboy 那个 netwizard（上面那行已注释）。
#★为什么不用 UPDATE_PACKAGE 的 pkg 模式：这个仓库的**仓库名与里面的包目录同名**
#  （都叫 luci-app-netwiz）。pkg 模式会 cp ./package/luci-app-netwiz/luci-app-netwiz
#  到 ./package/ —— 但 ./package/luci-app-netwiz 正是刚 clone 出来的仓库根（目录已存在），
#  于是复制成嵌套子目录，紧接着的 "rm -rf $REPO_PATH" 又把刚拷进去的内容一起删掉，
#  包直接消失。所以这里手动 clone 到临时目录 → 挪出包目录 → 删临时目录。
rm -rf ./package/luci-app-netwiz ./package/netwiz-src
git clone --depth=1 --single-branch --branch master "https://github.com/huchd0/luci-app-netwiz.git" ./package/netwiz-src
mv -f ./package/netwiz-src/luci-app-netwiz ./package/luci-app-netwiz
rm -rf ./package/netwiz-src

#★必做：补执行位，否则编进固件后整个插件是坏的（2026-10-14 实测踩过，别删这几行）
#  现象：ubus 里没有 netwiz 对象，前端所有调用都报
#        "RPCError: RPC call to netwiz/set_network failed with error -32000: Object not found"；
#        /etc/init.d/netwiz-* 也不能执行 → 防失联回滚（120s）完全不生效。
#  原因：这个仓库里所有脚本在 git 里的权限都是 644（没有执行位），而 luci.mk 装包时用的是
#        "cp -pR"（-p = 保留权限），于是 644 原样进包。官方 release 包不是这么来的 ——
#        作者自己的 CI 里有一句 "打包前赋予后端脚本执行权限"，显式 chmod 了下面这 8 个文件，
#        所以官方的 apk/ipk 是 755、装上就能用；我们从源码直接编就漏了这一步。
#  下面这 8 行与作者 CI 一一对应；再加一条 find 兜底，作者以后新增脚本也能自动带上执行位。
chmod 755 ./package/luci-app-netwiz/root/usr/libexec/rpcd/netwiz \
          ./package/luci-app-netwiz/root/usr/libexec/rpcd/netwiz_dev \
          ./package/luci-app-netwiz/root/usr/libexec/netwiz-autodetect.sh \
          ./package/luci-app-netwiz/root/usr/libexec/netwiz-monitor-loop.sh \
          ./package/luci-app-netwiz/root/etc/init.d/netwiz-monitor \
          ./package/luci-app-netwiz/root/etc/init.d/netwiz-recovery \
          ./package/luci-app-netwiz/root/etc/init.d/netwiz-watchdog \
          ./package/luci-app-netwiz/root/etc/hotplug.d/dhcp/99-netwiz-guard 2>/dev/null
find ./package/luci-app-netwiz/root/usr/libexec ./package/luci-app-netwiz/root/etc/init.d ./package/luci-app-netwiz/root/etc/hotplug.d \
     -type f -exec chmod 755 {} + 2>/dev/null

# natmapt 三件套已停用：本机家宽 NAT3~NAT4、无公网 IPv6，打洞类方案用不了，
# 改用 EasyTier（打不通自动走中继，见 Config/GENERAL.config 的「网络向导 / 组网」段）。
# 注释掉可以少 clone 三个源、少编译一批包。
# ★恢复时必须和 Config/GENERAL.config（及 TEST.config）里的 luci-app-natmapt / stuntman-client
#   一起改回 =y：只改配置不改这里 = 选中源码树里不存在的包，apk 阶段直接中断编译。
#UPDATE_PACKAGE "natmapt" "muink/openwrt-natmapt" "master"
#UPDATE_PACKAGE "stuntman" "muink/openwrt-stuntman" "master"
#UPDATE_PACKAGE "luci-app-natmapt" "muink/luci-app-natmapt" "master"

#======================= DDNSTO（linkease/ddnsto-openwrt-package）=======================
#内网穿透 / 远程访问。用官方自己维护的包仓库，里面两个包目录都要：
#  ddnsto          —— 主程序。闭源二进制，编译时从 koolcenter 拉预编译包（aarch64 那份）
#  luci-app-ddnsto —— LuCI 界面
#★不用 pkg 模式：两个包都要，直接整仓 clone 到 ./package/ 下最省事
#  （跟上面 sbwml 那几个仓库一个玩法，OpenWrt 能认到 ./package/<仓库>/<包> 这一层）。
#  第 5 个参数只是先把 feeds 里可能存在的同名旧包清掉。
UPDATE_PACKAGE "ddnsto" "linkease/ddnsto-openwrt-package" "main" "" "luci-app-ddnsto"

#★必做：换掉主程序二进制的下载地址（2026-10-16 实测，别删这一行）
#  官方 Makefile 里写的是 fw0.koolcenter.com，实测直接 404（只回 18 字节的 Not Found）；
#  fw.koolcenter.com 才是对的 —— 拉下来 16MB，sha256 与 Makefile 里的 PKG_HASH 完全一致。
#  这里改成「fw 在前、fw0 兜底」：download 按空格依次尝试，两个都挂了才会真的断编译。
if [ -f ./package/ddnsto-openwrt-package/ddnsto/Makefile ]; then
	sed -i 's|https://fw0\.koolcenter\.com/binary/ddnsto/linux-binary/|https://fw.koolcenter.com/binary/ddnsto/linux-binary/ https://fw0.koolcenter.com/binary/ddnsto/linux-binary/|g' ./package/ddnsto-openwrt-package/ddnsto/Makefile
fi

#======================= Docker（XiaoHaiSly/luci-app-dockerman）=======================
#整套组件都在一个仓库里：
#  dockerd(守护进程) / docker(CLI) / containerd / runc / docker-compose /
#  luci-app-dockerman(界面) / luci-lib-docker(界面依赖库)
#版本不用自己追：作者仓库每天自动跟 moby 发版同步
#  （核对时是 dockerd & docker 29.9.1、containerd 2.4.2、runc 1.5.2、compose 5.6.0）。
#★只给亚瑟装：1GB 内存 + 64GB eMMC 才有意义，兆能 M2（512MB 内存 + 128MB NAND）
#  装不下也跑不动，所以「选进固件」那几行只写在 Config/JDCloud-noWiFi.config，
#  不写进 GENERAL.config（那边是两台共用的）。
#  源码这里照拉 —— 没被选中的包不会被编译，M2 那条线不会因此变慢。
#★落位：5 个底层组件「替换进 feeds/packages/utils/」，不是整仓留在 ./package/ 下
#  （2026-10-16 改，思路来自群友十六夜）
#  这套 Makefile 本来就是按「包就在 feeds/packages/utils/ 下」写的，满是相对路径：
#     include ../../lang/golang/golang-package.mk     ← utils/X 往上两级才是 lang/golang
#     ../tini/Makefile   ../containerd/Makefile   ../runc/Makefile   ../docker/Makefile
#     $(CURDIR)/../dockerd/git-short-commit.sh
#  以前整仓 clone 到 ./package/ 下，这些相对路径全部指错，连着踩了三坑：
#     runc 的 include → docker-compose 的 include → dockerd 的 tini 校验，
#     每次都等价于白跑一整轮云编译。
#  换成塞进 feeds/packages/utils/ 覆盖 feed 自带那份之后，相对路径天然成立，
#  上游以后再加 Go 包、再加 ../ 校验都不会再来第四回。
#  留在 ./package/luci-app-dockerman/ 下的只有 luci-app-dockerman 和 luci-lib-docker
#  这两个 LuCI 界面包（它们没有相对路径依赖，不动）。
#★第 5 个参数只删 feeds 里的 LuCI 同名包，绝不写 "docker" ——
#  通配符杀伤力太强，会顺手删掉 python-docker / python-dockerpty 这类无关包；
#  docker/dockerd/docker-compose/containerd/runc 是打算直接覆盖的，用不着删。
#★同理：绝不能再手动清 package/feeds/packages/ 下的软链接 ——
#  Update Feeds 时 feed 给这 5 个包都建过软链接，正是要靠它们把包扫进编译系统，
#  删了就直接找不到包。（旧版那句 rm -f ./package/feeds/packages/*docker* 已删除）
UPDATE_PACKAGE "dockerman" "XiaoHaiSly/luci-app-dockerman" "main" "" "luci-lib-docker dockerman"

#把 5 个底层组件替换进 packages feed（Packages.sh 跑在 Update Feeds 之后，软链接已建好）
DOCKER_FEED_PATH="./feeds/packages/utils"
DOCKER_PKGS="docker dockerd containerd runc docker-compose"
mkdir -p "$DOCKER_FEED_PATH"
for DOCKER_PKG in $DOCKER_PKGS; do
	if [ -d "./package/luci-app-dockerman/$DOCKER_PKG" ]; then
		rm -rf "$DOCKER_FEED_PATH/$DOCKER_PKG"
		mv -f "./package/luci-app-dockerman/$DOCKER_PKG" "$DOCKER_FEED_PATH/$DOCKER_PKG"
		echo "docker: replaced $DOCKER_FEED_PATH/$DOCKER_PKG"
	fi
done
#兜底：万一 feed 没给某个包建软链接（实测 5 个都有），手动补一条，否则这包扫不进编译系统
mkdir -p ./package/feeds/packages
for DOCKER_PKG in $DOCKER_PKGS; do
	if [ ! -e "./package/feeds/packages/$DOCKER_PKG/Makefile" ]; then
		ln -sfn "$(pwd)/$DOCKER_FEED_PATH/$DOCKER_PKG" "./package/feeds/packages/$DOCKER_PKG"
		echo "docker: linked ./package/feeds/packages/$DOCKER_PKG"
	fi
done

#★下面四处补丁在新落位下其实已经可以不打，但保留作为安全网：
#  它们改完都是绝对路径，在两种落位下都成立；以后万一有人把这批包挪回去也不会再炸。
#  1) 用 Go 编译的包（runc、docker-compose）写的相对 include ../../lang/golang/… ——
#     原来在 ./package/ 下会指到仓库外面去（二跑 docker-compose 就断在第 26 行）。
for DOCKER_PKG in $DOCKER_PKGS; do
	DOCKER_MK="$DOCKER_FEED_PATH/$DOCKER_PKG/Makefile"
	[ -f "$DOCKER_MK" ] || continue
	sed -i 's|include ../../lang/golang/golang-package.mk|include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk|' "$DOCKER_MK"
done
#  2) docker(CLI) 在 Build/Prepare 里拿 $(CURDIR)/../dockerd/git-short-commit.sh 校验 commit，
#     $(CURDIR) 到底指编译根目录还是包目录并不稳定 → 一律改成绝对路径，落到 feeds 里这份。
if [ -f "$DOCKER_FEED_PATH/docker/Makefile" ]; then
	sed -i 's|\$(CURDIR)/../dockerd/git-short-commit.sh|$(TOPDIR)/feeds/packages/utils/dockerd/git-short-commit.sh|' "$DOCKER_FEED_PATH/docker/Makefile"
fi
#  3) dockerd 依赖 uci-firewall，但这个包在 immortalwrt/packages、openwrt/packages、
#     immortalwrt 主干里全都搜不到（只在第三方小包仓库里见过），依赖解析不了会中断整轮编译；
#     翻过 dockerd.init —— 它只用 uci 命令改防火墙配置，并不需要这个包 → 去掉这行依赖。
if [ -f "$DOCKER_FEED_PATH/dockerd/Makefile" ]; then
	sed -i '/+uci-firewall/d' "$DOCKER_FEED_PATH/dockerd/Makefile"
fi
#  4) dockerd 校验 ../tini/Makefile 的版本要等于 0.19.0，而 feed 里那份就在
#     feeds/packages/utils/tini（同为 0.19.0）；上游自己的仓库压根没带 tini 目录，
#     所以这行以前必然踩空（grep 报 No such file → Prepared 退出 1 → 整轮 world 编译断）。
#     正常就应该指向 feed 那份；万一哪天 feed 把它挪走/改名，就退一步删掉这行校验，
#     绝不留下悬空检查。
if [ -f "$DOCKER_FEED_PATH/dockerd/Makefile" ]; then
	if [ -f "$DOCKER_FEED_PATH/tini/Makefile" ]; then
		sed -i 's|call EnsureVendoredVersion,\.\./tini/Makefile|call EnsureVendoredVersion,$(TOPDIR)/feeds/packages/utils/tini/Makefile|' "$DOCKER_FEED_PATH/dockerd/Makefile"
	else
		sed -i '/call EnsureVendoredVersion,\.\.\/tini\//d' "$DOCKER_FEED_PATH/dockerd/Makefile"
	fi
fi

#======================= iStore / QuickStart（只有京东云亚瑟装）=======================
#成品界面就是 https://<路由>/cgi-bin/luci/admin/quickstart/ 那一页：
#  QuickStart 仪表盘 / NetworkGuide 网络向导 / NetworkPort 网口配置，
#  外加 iStoreX 首页和 iStore 商店。
#★只给亚瑟装：这一批包全部只写在 Config/JDCloud-noWiFi.config，不进 GENERAL.config
#  （GENERAL 是两台共用的，兆能 M2 一概不装）。
#  源码这里照拉 —— 没被选中的包不会被编译，M2 那条线不会因此变慢。
#★为什么不用 UPDATE_PACKAGE 的 pkg 模式逐个拉：
#  这些包都在 kenzok8/small-package 这个「大杂烩」仓库里（几千个包），整仓 clone 会
#  污染包树、拖慢 feeds 扫描；pkg 模式一次又只能取一个包、且遇到「仓库名与包目录同名」
#  还会踩 NetWiz 那个嵌套复制被删的坑。
#  所以用 sparse-checkout：只把需要的目录拉下来，再各自拷进 ./package/。
ISTORE_PKGS="luci-app-istorex luci-app-quickstart quickstart luci-app-store luci-lib-taskd taskd luci-lib-xterm luci-app-lucky lucky luci-app-adguardhome adguardhome"
rm -rf ./istore-src
git clone --depth=1 --filter=blob:none --sparse --branch main "https://github.com/kenzok8/small-package.git" ./istore-src
git -C ./istore-src sparse-checkout set $ISTORE_PKGS
for ISTORE_PKG in $ISTORE_PKGS; do
	if [ -d "./istore-src/$ISTORE_PKG" ]; then
		rm -rf "./package/$ISTORE_PKG"
		cp -R "./istore-src/$ISTORE_PKG" "./package/$ISTORE_PKG"
		echo "istore: $ISTORE_PKG"
	else
		echo "istore: WARNING $ISTORE_PKG not found, skipped"
	fi
done
rm -rf ./istore-src

#★必做补丁 1：quickstart 后端的 DEPENDS 里挂着 +mdadm（软 RAID 阵列）。
#  家用单盘路由根本用不上，而它会把一整套 kmod-md-* 内核模块拉进固件。
#  （ZqinKing 把他那份里的 e2fsprogs / parted / smartmontools / smartd / drivedb / mdadm
#    全去了；我们这边 GENERAL.config 本来就开着 smartmontools 和 drivedb，
#    e2fsprogs / parted 对有 USB 口的亚瑟也算磁盘工具，留着。
#    只去掉明确用不上且会拖进一堆内核模块的 mdadm，改动最小。）
if [ -f ./package/quickstart/Makefile ]; then
	sed -i 's/[[:space:]]*+mdadm//g' ./package/quickstart/Makefile
fi

#★必做补丁 2：luci-app-adguardhome 的 DEPENDS 写的是 +ca-certs，
#  但源码树里根本没有这个包（全树搜过，主干只有 package/system/ca-certificates）——
#  跟 dockerd 那个 uci-firewall 是同一类坑：apk 体系下依赖解析不了是**直接中断编译**的，
#  不像 opkg 那样只给个警告。必须改成正确的包名。
if [ -f ./package/luci-app-adguardhome/Makefile ]; then
	sed -i 's/+ca-certs\b/+ca-certificates/g' ./package/luci-app-adguardhome/Makefile
fi

#======================= eMMC 健康（adminchenyu/eMMC-Health）======================
#亚瑟是 64GB eMMC，看寿命 / 健康度 / Pre-EOL 有意义；M2 是 128MB NAND，用不上
#  （所以选包那行只写在 Config/JDCloud-noWiFi.config）。
#★这个仓库根目录本身就是包目录（PKG_NAME 写在根 Makefile 里），
#  所以整仓 clone 后直接把目录名改成包名 luci-app-emmc-health 即可。
rm -rf ./package/luci-app-emmc-health
git clone --depth=1 --single-branch --branch main "https://github.com/adminchenyu/eMMC-Health.git" ./package/luci-app-emmc-health

#★必做补丁：去掉 +luci-js-deps —— immortalwrt 主干里没有这个包（全树搜不到），
#  留着就是一条解析不了的依赖，apk 阶段必断。
#  做法与 ZqinKing 的 fix_emmc_health_luci_js_deps 完全一致。
if [ -f ./package/luci-app-emmc-health/Makefile ]; then
	sed -i '/^[[:space:]]*DEPENDS:=/ s/[[:space:]]*+luci-js-deps//g' ./package/luci-app-emmc-health/Makefile
fi

#======================= OAF 应用过滤（destan19/OpenAppFilter）★已停用 =======================
#停用原因（2026-10-17 TEST 实证，三条）：
#  1) 内核模块根本选不上：defconfig 报
#         error: recursive dependency detected!
#           symbol PACKAGE_kmod-oaf is selected by PACKAGE_kmod-oaf
#     kconfig 判为 broken 后不再传播 select，生成的 .config 里
#     CONFIG_PACKAGE_kmod-oaf 就是 "is not set" —— 界面在、模块不在，功能必然残废。
#  2) oaf 是 out-of-tree 内核模块，跟内核版本强相关，6.18 / 6.12 都有编不过的风险。
#  3) IPQ6000 开了 NSS 硬件加速后，流量走硬件转发路径、不过 netfilter 钩子，
#     就算装上了功能本身也失效（跟 SQM 在 NSS 下的处境一样）。
#★恢复方法：取消下面这行的注释，同时取消 Config/JDCloud-noWiFi.config 里
#  luci-app-oaf / luci-i18n-oaf-zh-cn / appfilter 三行的注释 —— 两处必须一起改，
#  否则选中一个源码树里不存在的包，apk 阶段会直接中断编译。
#  第 5 个参数是清掉 feeds 里可能存在的同名旧包 —— 上游注释说不清会出现 coremark 报错。
#UPDATE_PACKAGE "OpenAppFilter" "destan19/OpenAppFilter" "master" "" "luci-app-appfilter oaf appfilter"

UPDATE_PACKAGE "airpi3000m-fancontrol" "LianXia233/luci-app-airpi3000m-fancontrol" "main"
UPDATE_PACKAGE "chfs" "LianXia233/luci-app-chfs" "main"
UPDATE_PACKAGE "fm350" "LianXia233/luci-app-fm350" "main"
UPDATE_PACKAGE "h5000m-netmode" "LianXia233/luci-app-h5000m-netmode" "main"
UPDATE_PACKAGE "mt5700" "LianXia233/luci-app-mt5700" "main"
UPDATE_PACKAGE "mt5700m" "LianXia233/luci-app-mt5700m" "main"
UPDATE_PACKAGE "netmonitor" "LianXia233/luci-app-netmonitor" "main"
UPDATE_PACKAGE "qmodem-generic" "LianXia233/luci-app-qmodem-generic" "main"

#更新软件包版本
UPDATE_VERSION() {
	local PKG_NAME=$1
	local PKG_MARK=${2:-false}
	local PKG_FILES=$(find ./ ./feeds/packages/ -maxdepth 3 -type f -wholename "*/$PKG_NAME/Makefile")

	if [ -z "$PKG_FILES" ]; then
		echo "$PKG_NAME not found!"
		return
	fi

	echo -e "\n$PKG_NAME version update has started!"

	for PKG_FILE in $PKG_FILES; do
		local PKG_REPO=$(grep -Po "PKG_SOURCE_URL:=https://.*github.com/\K[^/]+/[^/]+(?=.*)" $PKG_FILE)
		local PKG_TAG=$(curl -sL "https://api.github.com/repos/$PKG_REPO/releases" | jq -r "map(select(.prerelease == $PKG_MARK)) | first | .tag_name")

		local OLD_VER=$(grep -Po "PKG_VERSION:=\K.*" "$PKG_FILE")
		local OLD_URL=$(grep -Po "PKG_SOURCE_URL:=\K.*" "$PKG_FILE")
		local OLD_FILE=$(grep -Po "PKG_SOURCE:=\K.*" "$PKG_FILE")
		local OLD_HASH=$(grep -Po "PKG_HASH:=\K.*" "$PKG_FILE")

		local PKG_URL=$([[ "$OLD_URL" == *"releases"* ]] && echo "${OLD_URL%/}/$OLD_FILE" || echo "${OLD_URL%/}")

		local NEW_VER=$(echo $PKG_TAG | sed -E 's/[^0-9]+/\./g; s/^\.|\.$//g')
		local NEW_URL=$(echo $PKG_URL | sed "s/\$(PKG_VERSION)/$NEW_VER/g; s/\$(PKG_NAME)/$PKG_NAME/g")
		local NEW_HASH=$(curl -sL "$NEW_URL" | sha256sum | cut -d ' ' -f 1)

		echo "old version: $OLD_VER $OLD_HASH"
		echo "new version: $NEW_VER $NEW_HASH"

		if [[ "$NEW_VER" =~ ^[0-9].* ]] && dpkg --compare-versions "$OLD_VER" lt "$NEW_VER"; then
			sed -i "s/PKG_VERSION:=.*/PKG_VERSION:=$NEW_VER/g" "$PKG_FILE"
			sed -i "s/PKG_HASH:=.*/PKG_HASH:=$NEW_HASH/g" "$PKG_FILE"
			echo "$PKG_FILE version has been updated!"
		else
			echo "$PKG_FILE version is already the latest!"
		fi
	done
}

#UPDATE_VERSION "软件包名" "测试版，true，可选，默认为否"
#UPDATE_VERSION "sing-box"

#引入私有扩展脚本
if [ -f "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh" ]; then
	source "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh"
fi
