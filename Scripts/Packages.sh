#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
#
# 移植自 laipeng668/openwrt-ci-roc 的 Roc-script.sh：
#   1) 按需拉包：先读 Config/$WRT_CONFIG.config + Config/GENERAL.config，配置里没选中的包整段跳过
#   2) 克隆重试：单个仓库网络抖动最多重试 3 次，不再一次失败就整构建崩掉
#   3) 源码溯源：把每个第三方仓库的 repo/branch/commit 记进 third-party-sources.txt

WORKSPACE="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GIT_CLONE_RETRY_COUNT="${GIT_CLONE_RETRY_COUNT:-3}"

#运行目录约定：本脚本要在源码的 package/ 目录下执行（WRT-CORE 里是 cd ./wrt/package/ 之后再调），
#因为下面删重名包用的是 ../feeds/...，拉包则是直接落到当前目录。
#上游 VIKINGYFY 原版是在源码根目录执行、目标写死 ./package；两种约定不兼容，
#这里做一次归一化：如果看起来是在源码根目录被调用，就自动进到 package/，避免误删或包放错位置。
if [ -d ./package ] && [ ! -d ../feeds ]; then
	cd ./package || exit 1
fi
THIRD_PARTY_SOURCES_FILE="${THIRD_PARTY_SOURCES_FILE:-$WORKSPACE/third-party-sources.txt}"

#溯源表初始化
mkdir -p "$(dirname "$THIRD_PARTY_SOURCES_FILE")"
printf 'Repository\tBranch\tCommit\n' > "$THIRD_PARTY_SOURCES_FILE"

#待解析的配置文件：机型配置 + 通用配置（此时 .config 尚未生成，直接读源文件）
#自包含清单架构：Config/<配置>.config 已经是完整清单，GENERAL.config 是共用基座。
#★顺序是「机型配置 → GENERAL.config」，GENERAL 在后 → 同一 key 由 GENERAL 说了算。
#  所以机型层写的 =n 压不住 GENERAL 里的 =y，反过来 GENERAL 的 =y 会盖掉机型的 =n。
#  （此前的注释写反了，害得 ZNM2 的五个 =n 以为生效实则没生效；已连同 GENERAL.config 一起
#   改掉解决 —— 详见 GENERAL.config 的「为什么这里越来越短」一节。）
#本文件的扫描结果只用于决定「要不要 clone 某个第三方包源」，真正生成 .config 的合并在
#WRT-CORE.yml 的 Custom Settings 步骤，那里的 cat 顺序同样是机型在前、GENERAL 在后。
#（早期还有一层 Config/*-Override.config 按设备关键词自动追加，现已取消 ——
# 亚瑟要出 WiFi 与 noWiFi 两份，Override 只认设备名分辨不了形态，见 Settings.sh 注释。）
WRT_CONFIG_FILES=()
if [ -n "${WRT_CONFIG:-}" ] && [ -f "$WORKSPACE/Config/$WRT_CONFIG.config" ]; then
	WRT_CONFIG_FILES+=("$WORKSPACE/Config/$WRT_CONFIG.config")
fi
if [ -f "$WORKSPACE/Config/GENERAL.config" ]; then
	WRT_CONFIG_FILES+=("$WORKSPACE/Config/GENERAL.config")
fi
#★最终裁决层（PRIVATE）也必须扫进来，否则会出「包选了却拉不到」的怪事：
#  在 PRIVATE 里写了 CONFIG_PACKAGE_xxx=y 想装某个第三方插件，而本脚本没扫这个文件，
#  就判定「配置里没选中」而跳过 clone —— 后面 defconfig 时这个包根本不存在，
#  轻则静默装不上，重则在 package/install 阶段报 unable to select packages 中断编译。
#下面的顺序必须与 Settings.sh / WRT-CORE.yml 里 .config 的合并顺序一致
#（越靠后优先级越高）：机型 → GENERAL → PRIVATE.config（通用）→ PRIVATE-<配置>.config（特定）。
#PRIVATE-<配置>.config 排最后，是为了让「针对某一台的定夺」能压过「对所有台的统一设定」。
if [ -f "$WORKSPACE/Config/PRIVATE.config" ]; then
	WRT_CONFIG_FILES+=("$WORKSPACE/Config/PRIVATE.config")
fi
if [ -n "${WRT_CONFIG:-}" ] && [ -f "$WORKSPACE/Config/PRIVATE-$WRT_CONFIG.config" ]; then
	WRT_CONFIG_FILES+=("$WORKSPACE/Config/PRIVATE-$WRT_CONFIG.config")
fi

#一次性扫描全部配置文件，建立「已启用包名」索引
#只跑一次 awk：早期版本每个候选包名都 fork 一次 awk，30 个包 × 5 个候选名 = 上百次进程创建，
#在 fork 昂贵的环境里能把这一步拖到一分钟以上。这里改成单次扫描 + 关联数组查表。
#扫描顺序 = 机型配置 → GENERAL，后出现的同名行覆盖前面的结果 —— 注意是「后出现者胜」，
#而 GENERAL 排在后，所以 GENERAL 的 =y 会盖掉机型层的 =n（=n 盖不掉 =y，别记反了）。
declare -A WRT_ENABLED_PKGS=()
if [ "${#WRT_CONFIG_FILES[@]}" -gt 0 ]; then
	WRT_PKG_SCAN="$(
		awk '
			{ sub(/\r$/, "") }
			/^CONFIG_PACKAGE_.+=[ym]$/ {
				name = $0
				sub(/^CONFIG_PACKAGE_/, "", name)
				sub(/=[ym]$/, "", name)
				print "P\t" name
				next
			}
			/^CONFIG_PACKAGE_.+=n$/ {
				name = $0
				sub(/^CONFIG_PACKAGE_/, "", name)
				sub(/=n$/, "", name)
				print "N\t" name
				next
			}
			/^CONFIG_TARGET_DEVICE_PACKAGES_[^=]+="/ {
				line = $0
				sub(/^[^"]*"/, "", line)
				sub(/"$/, "", line)
				count = split(line, values, /[[:space:]]+/)
				for (i = 1; i <= count; i++) {
					if (values[i] != "") print "P\t" values[i]
				}
			}
		' "${WRT_CONFIG_FILES[@]}"
	)"

	while IFS=$'\t' read -r flag name; do
		[ -n "$name" ] || continue
		if [ "$flag" = "P" ]; then
			WRT_ENABLED_PKGS["$name"]=1
		else
			unset "WRT_ENABLED_PKGS[$name]"
		fi
	done <<< "$WRT_PKG_SCAN"
fi

#任一个候选包名被选中即返回 0
#读不到任何配置文件时一律返回 0 —— 保持原来的「全量拉包」行为，不会因为解析失败而漏包
package_enabled() {
	local package_name
	[ "${#WRT_CONFIG_FILES[@]}" -gt 0 ] || return 0
	for package_name in "$@"; do
		if [ -n "${WRT_THEME:-}" ] && [[ "$package_name" == *"$WRT_THEME"* ]]; then
			return 0
		fi
		if [ -n "${WRT_ENABLED_PKGS[$package_name]:-}" ]; then
			return 0
		fi
	done
	return 1
}

#带重试的克隆
clone_with_retry() {
	local target_dir="$1"
	local attempt
	shift

	for ((attempt = 1; attempt <= GIT_CLONE_RETRY_COUNT; attempt++)); do
		rm -rf "$target_dir"
		if git clone "$@" "$target_dir"; then
			return 0
		fi
		if [ "$attempt" -lt "$GIT_CLONE_RETRY_COUNT" ]; then
			echo "Git clone failed; retrying ($((attempt + 1))/$GIT_CLONE_RETRY_COUNT)" >&2
			sleep $((attempt * 2))
		fi
	done

	echo "Error: git clone failed after $GIT_CLONE_RETRY_COUNT attempts" >&2
	return 1
}

#记录第三方源码版本
record_git_revision() {
	local repo_url="$1"
	local branch="$2"
	local checkout_dir="$3"
	local commit
	local revision

	commit="$(git -C "$checkout_dir" rev-parse HEAD 2>/dev/null)" || return 0
	printf -v revision '%s\t%s\t%s' "$repo_url" "$branch" "$commit"
	grep -Fqx -- "$revision" "$THIRD_PARTY_SOURCES_FILE" || printf '%s\n' "$revision" >> "$THIRD_PARTY_SOURCES_FILE"
}

#安装和更新软件包
UPDATE_PACKAGE() {
	local PKG_NAME=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	local PKG_SPECIAL=$4
	local PKG_LIST=("$PKG_NAME" $5)  # 第5个参数为自定义名称列表
	local REPO_NAME=${PKG_REPO#*/}

	echo " "

	# 删除本地可能存在的不同名称的软件包
	for NAME in "${PKG_LIST[@]}"; do
		# 查找匹配的目录
		echo "Search directory: $NAME"
		local FOUND_DIRS=$(find ../feeds/luci/ ../feeds/packages/ ../feeds/smpackage/ -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null)

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

	# 克隆 GitHub 仓库（带重试 + 记录 commit）
	clone_with_retry "$REPO_NAME" --depth=1 --no-tags --single-branch --branch $PKG_BRANCH "https://github.com/$PKG_REPO.git"
	record_git_revision "$PKG_REPO" "$PKG_BRANCH" "$REPO_NAME"

	# 处理克隆的仓库
	if [[ "$PKG_SPECIAL" == "pkg" ]]; then
		find ./$REPO_NAME/*/ -maxdepth 3 -type d -iname "*$PKG_NAME*" -prune -exec cp -rf {} ./ \;
		rm -rf ./$REPO_NAME/
	elif [[ "$PKG_SPECIAL" == "name" ]]; then
		mv -f $REPO_NAME $PKG_NAME
	fi
}

#按需拉包包装：配置里没出现的包直接跳过，不再无条件 clone
#用法与 UPDATE_PACKAGE 完全一致，只是多了一道配置判断
UPDATE_PACKAGE_OPT() {
	local PKG_NAME=$1
	shift

	if package_enabled "$PKG_NAME" "luci-$PKG_NAME" "luci-app-$PKG_NAME" "luci-theme-$PKG_NAME" "luci-i18n-$PKG_NAME-zh-cn"; then
		UPDATE_PACKAGE "$PKG_NAME" "$@"
	else
		echo "skip $PKG_NAME: not selected in Config/$WRT_CONFIG.config or Config/GENERAL.config"
	fi
}

#稀疏克隆：从「大杂烩」仓库里只取一个子目录，不把整个仓库拉下来。
#典型用途是 x-wrt/com.x-wrt —— 它有 500+ 个包、5000+ 次提交，全量 --depth=1 也要几百 MB
#且拖慢整个 Custom Packages 步骤；用 --sparse + sparse-checkout 只取 luci-app-wizard
#一个目录，几秒钟完成。
#参数：$1 包名（落到本地的目录名） $2 仓库 $3 分支 $4 仓库内子目录（默认与包名同名）
UPDATE_PACKAGE_SPARSE() {
	local PKG_NAME=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	local PKG_SUBDIR=${4:-$PKG_NAME}
	local REPO_NAME=${PKG_REPO#*/}
	local TMP_DIR="${REPO_NAME}-sparse"

	#先清掉 feeds 与本地可能存在的同名旧包，避免重复定义（与 UPDATE_PACKAGE 的做法一致）
	local FOUND_DIRS
	FOUND_DIRS=$(find ../feeds/luci/ ../feeds/packages/ ../feeds/smpackage/ -maxdepth 3 -type d -iname "*$PKG_NAME*" 2>/dev/null)
	if [ -n "$FOUND_DIRS" ]; then
		while read -r DIR; do
			rm -rf "$DIR"
			echo "Delete directory: $DIR"
		done <<< "$FOUND_DIRS"
	fi
	rm -rf "./$PKG_NAME" "$TMP_DIR"

	clone_with_retry "$TMP_DIR" --depth=1 --no-tags --single-branch \
		--filter=blob:none --sparse --branch "$PKG_BRANCH" "https://github.com/$PKG_REPO.git"
	record_git_revision "$PKG_REPO" "$PKG_BRANCH" "$TMP_DIR"

	git -C "$TMP_DIR" sparse-checkout set "$PKG_SUBDIR" 2>/dev/null
	if [ -d "$TMP_DIR/$PKG_SUBDIR" ]; then
		mv -f "$TMP_DIR/$PKG_SUBDIR" "./$PKG_NAME"
		echo "sparse-cloned $PKG_SUBDIR -> package/$PKG_NAME"
	else
		echo "::warning::$PKG_REPO 里没找到子目录 $PKG_SUBDIR，$PKG_NAME 未安装"
	fi
	rm -rf "$TMP_DIR"
}

# 调用示例
# UPDATE_PACKAGE "OpenAppFilter" "destan19/OpenAppFilter" "master" "" "custom_name1 custom_name2"
# UPDATE_PACKAGE "open-app-filter" "destan19/OpenAppFilter" "master" "" "luci-app-appfilter oaf" 这样会把原有的open-app-filter，luci-app-appfilter，oaf相关组件删除，不会出现cor[...]

# UPDATE_PACKAGE "包名" "项目地址" "项目分支" "pkg/name，可选，pkg为从大杂烩中单独提取包名插件；name为重命名为包名"
UPDATE_PACKAGE_OPT "argon" "sbwml/luci-theme-argon" "openwrt-25.12"
UPDATE_PACKAGE_OPT "aurora" "eamonxg/luci-theme-aurora" "master"
UPDATE_PACKAGE_OPT "aurora-config" "eamonxg/luci-app-aurora-config" "master"
UPDATE_PACKAGE_OPT "kucat" "sirpdboy/luci-theme-kucat" "master"
UPDATE_PACKAGE_OPT "kucat-config" "sirpdboy/luci-app-kucat-config" "master"
UPDATE_PACKAGE_OPT "noobwrt" "nooblk-98/luci-theme-noobwrt" "master"
UPDATE_PACKAGE_OPT "shadcn" "eamonxg/luci-theme-shadcn" "main"
UPDATE_PACKAGE_OPT "theme-fluent" "LazuliKao/luci-theme-fluent" "main"

UPDATE_PACKAGE_OPT "momo" "nikkinikki-org/OpenWrt-momo" "main"
UPDATE_PACKAGE_OPT "nikki" "nikkinikki-org/OpenWrt-nikki" "main"
UPDATE_PACKAGE_OPT "openclash" "vernesong/OpenClash" "dev" "pkg"
UPDATE_PACKAGE_OPT "passwall" "Openwrt-Passwall/openwrt-passwall" "main" "pkg"
UPDATE_PACKAGE_OPT "passwall2" "Openwrt-Passwall/openwrt-passwall2" "main" "pkg"

#---- 2026-10-12 新增：首页汇总页 / AdGuard Home / eMMC 健康 / Docker 管理界面 ----
#▲kenzok8/small-package 其实早就作为 smpackage feed 注入了（WRT-CORE.yml 的 Update Feeds），
#  但走 feed 有个坑：feeds install -a 时 packages/luci 排在 smpackage 前面先占住包名，
#  而官方版又被 WRT-CORE.yml 的「删官方同名包」那步 rm 掉了 —— 两边都装不上，
#  包从源码树里彻底消失（JDCloud-WiFi.config 第九节记的那 119 个包就是这么没的，
#  adguardhome 正在名单里）。
#  所以这里不走 feeds，直接用 UPDATE_PACKAGE 把包落到 wrt/package/ 下：这个目录优先级高于
#  feeds，且 Custom Packages 步骤排在 feeds install 之后，不会再被那轮清理删掉。
#★pkg 模式的 find 用 -iname "*名字*"，一次调用会把同名前缀的包一起抽出来：
#  "quickstart"  → quickstart + luci-app-quickstart
#  "adguardhome" → adguardhome + luci-app-adguardhome
UPDATE_PACKAGE_OPT "quickstart" "kenzok8/small-package" "main" "pkg"
#quickstart 首页依赖精简（照抄 ZqinKing 的 fix_quickstart()）：
#  上游 quickstart 的 Makefile 在 DEPENDS 里挂了 smartmontools / smartmontools-drivedb /
#  mdadm / parted / e2fsprogs —— 这些是"硬盘健康与阵列"相关的重家伙，一个状态首页
#  根本用不到，却会被 defconfig 一起拉进固件。ZqinKing 的做法是把它们从 DEPENDS 摘掉。
#  ★只删依赖、不新增，所以不会引入"缺依赖"风险（apk 下缺依赖才是致命错误）。
if [ -f ./quickstart/Makefile ]; then
	sed -i \
		-e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+smartmontools-drivedb//g' \
		-e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+smartmontools//g' \
		-e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+mdadm//g' \
		-e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+parted//g' \
		-e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+e2fsprogs//g' \
		./quickstart/Makefile
	echo "已移除 quickstart 的非必要存储依赖（smartmontools/mdadm/parted/e2fsprogs）"
fi
UPDATE_PACKAGE_OPT "adguardhome" "kenzok8/small-package" "main" "pkg"
#======================= network_guide：首启网络设置向导 =======================
#★要的效果是 ZqinKing 那种多页向导：/cgi-bin/luci/admin/network_guide/pages/network
#  —— 它不是一个单一入口，而是 pages/network → pages/wan → pages/lan 一串分页流程。
#  这个东西就是 **luci-app-wizard**（X-WRT 血统，作者 ptpt52 = X-WRT 创始人 Chen Minqiang），
#  admin/network_guide 是它 controller 里注册的路由，pages/* 是 htdocs 下的向导分页。
#★2026-10-13 改源：原先从 kenzok8/small-package 以 pkg 模式抽，抽出来的目录要看它同步
#  得全不全，不够稳。这里改成**直接从上游 x-wrt/com.x-wrt 稀疏克隆**，拿到的就是
#  官方完整版（含 htdocs/luci-static/resources/view/wizard 下的整组分页），
#  与 ZqinKing 那台机器上看到的效果对得上。
#  用稀疏克隆是因为 com.x-wrt 是 500+ 包的大仓库，全量拉太重。
#进度记在 /etc/config/wizard（包内 conffiles），配完不再自动跳出。
#与 netwizard（sirpdboy，本文件下方）的分工：netwizard 是「平时进菜单手动切拨号/旁路由/
#  静态 IP」；wizard 是「第一次开机自动引导」。一个偏首次上手、一个偏日常切换，互补不冲突。
#LUCI_DEPENDS 为空（2026-10-13 查证 Makefile），无额外依赖，apk 下不会因缺依赖中断编译。
if package_enabled "luci-app-wizard" "luci-i18n-wizard-zh-cn"; then
	UPDATE_PACKAGE_SPARSE "luci-app-wizard" "x-wrt/com.x-wrt" "master"
else
	echo "skip luci-app-wizard: not selected in Config/$WRT_CONFIG.config or Config/GENERAL.config"
fi
#eMMC 健康监测：单包仓库，仓库根目录就是 Makefile，用 name 模式把目录重命名为包名。
UPDATE_PACKAGE_OPT "luci-app-emmc-health" "adminchenyu/eMMC-Health" "main" "name"
#  坑：它的 Makefile 声明了 +luci-js-deps 依赖，但 luci-js-deps 在当前源码树里不存在
#  （immortalwrt 与 openwrt 的 luci feed 里都没有这个包），apk 会在 package/install 阶段报
#  "unable to select packages: luci-js-deps" 把整个编译打断。ZqinKing 也是这么处理的 ——
#  它专门写了 fix_emmc_health_luci_js_deps() 干同一件事。
#  luci-js-deps 只是「把 JS 依赖打进包」的构建机制，去掉不影响页面功能。
if [ -f ./luci-app-emmc-health/Makefile ]; then
	sed -i '/^[[:space:]]*DEPENDS:=/ s/[[:space:]]*+luci-js-deps//g' ./luci-app-emmc-health/Makefile
	echo "已移除 luci-app-emmc-health 的 luci-js-deps 依赖（当前源码树里没有这个包）"
fi
#Docker 管理界面：WRT-CORE.yml 把 smpackage 的 luci-app-dockerman 删了、官方 luci feed 里
#  又没有 dockerman（它从来就不在官方），所以这个界面同样从源码树里消失了。
#  docker / dockerd / containerd / runc 本体在 packages feed 里是好的（WRT-CORE.yml 特意
#  保留官方已验证的 29.6.1），缺的只是这个 LuCI 界面 —— 从这里补。
UPDATE_PACKAGE_OPT "luci-app-dockerman" "lisaac/luci-app-dockerman" "master"

UPDATE_PACKAGE_OPT "luci-app-tailscale" "asvow/luci-app-tailscale" "main"

#======================= 京东云 LED 控制（★灭灯 BUG 的修复项，勿再注释掉）=======================
#背景：亚瑟（京东云雅典娜 / RE-SS-01 / AX1800 Pro）的指示灯不是普通 GPIO LED，
#  需要 athena_led 这个常驻服务定时下发状态，否则灯没有一个"主人"，
#  表现就是「开机时亮着 → 跑一阵子熄灭 → 重启也不亮」，肉眼看像机器坏了。
#  ★本机这两台设备都出现过，刷别的作者的固件就没这现象 —— 查下来三位参考作者
#    （breeze303 / laipeng668 / ZqinKing）**全都装了这个插件**，只有我们把它注释掉了：
#      breeze303  libwrt.sh:      rm -rf package/emortal/luci-app-athena-led && clone NONGFAH 版
#      laipeng668 Roc-script.sh:  clone_repository NONGFAH/luci-app-athena-led
#      ZqinKing   jdcloud 配置:   luci-app-athena-led=m + re-cs-02 设备包里也带
#  原先注释掉的那行用的是 unraveloop 的旧仓库，现统一改成三家都在用的 NONGFAH 版。
UPDATE_PACKAGE_OPT "athena-led" "NONGFAH/luci-app-athena-led" "main"
#拉下来之后还要补两件上游没做的事：
#  1) 删掉 immortalwrt 自带的 package/emortal/luci-app-athena-led —— 它是旧版，
#     留着会和 NONGFAH 版重复定义（breeze303 的 libwrt.sh 第 1 行就是干这个）。
#  2) chmod +x：上游仓库里 init.d / usr/sbin 下的脚本没有可执行位，不补的话装进固件后
#     athena_led 服务根本起不来，LED 依旧没人维护，等于白装。三家作者都做了这一步。
if [ -d ./luci-app-athena-led ]; then
	rm -rf ./emortal/luci-app-athena-led 2>/dev/null
	chmod +x ./luci-app-athena-led/root/etc/init.d/athena_led \
		./luci-app-athena-led/root/usr/sbin/athena-led 2>/dev/null
	echo "luci-app-athena-led installed (JDCloud Athena LED controller)"
fi
UPDATE_PACKAGE_OPT "ddns-go" "sirpdboy/luci-app-ddns-go" "main"
UPDATE_PACKAGE_OPT "diskman" "sbwml/luci-app-diskman" "main"
UPDATE_PACKAGE_OPT "mini-diskmanager" "4IceG/luci-app-mini-diskmanager" "main"
UPDATE_PACKAGE_OPT "easytier" "EasyTier/luci-app-easytier" "main"
UPDATE_PACKAGE_OPT "mosdns" "sbwml/luci-app-mosdns" "v5" "" "v2dat"
UPDATE_PACKAGE_OPT "netspeedtest" "sirpdboy/netspeedtest" "main" "" "homebox ookla-speedtest"
UPDATE_PACKAGE_OPT "netwizard" "sirpdboy/luci-app-netwizard" "main"
UPDATE_PACKAGE_OPT "openlist2" "sbwml/luci-app-openlist2" "main"
UPDATE_PACKAGE_OPT "partexp" "sirpdboy/luci-app-partexp" "main"
UPDATE_PACKAGE_OPT "qbittorrent" "sbwml/luci-app-qbittorrent" "master" "" "qt6base qt6tools rblibtorrent"
UPDATE_PACKAGE_OPT "qmodem" "FUjr/QModem" "main"
UPDATE_PACKAGE_OPT "quickfile" "sbwml/luci-app-quickfile" "main"
UPDATE_PACKAGE_OPT "timecontrol" "sirpdboy/luci-app-timecontrol" "main"
#viking 不参与按需判断：它同时提供 homeproxy / gecoosac / wolultra / sing-box，
#这些包在 GENERAL.config 里以各自的名字出现，按 "viking" 匹配不到，必须无条件拉取。
UPDATE_PACKAGE "viking" "VIKINGYFY/packages" "main" "" "axonhub gecoosac sing-box luci-app-homeproxy luci-app-timewol luci-app-wolplus luci-app-wolultra"
UPDATE_PACKAGE_OPT "vnt" "lmq8267/luci-app-vnt" "main"

# 4G/5G 通用拨号工具（与 qmodem 互补，支持更多型号 USB 模块）
UPDATE_PACKAGE_OPT "qmodem-generic" "LianXia233/luci-app-qmodem-generic" "main"

# Open-Box 已移除：liandu2024/Open-Box 是"一键安装脚本"仓库（只有 README/docs/scripts），
# 不含任何 OpenWrt 包目录，UPDATE_PACKAGE 提取不到 open-box 包，只会白克隆一次仓库。
# 需要 Open-Box 请在刷好固件后用其官方 install.sh 在路由器上安装。

#更新软件包版本
UPDATE_VERSION() {
	local PKG_NAME=$1
	local PKG_MARK=${2:-false}
	local PKG_FILES=$(find ./ ../feeds/packages/ -maxdepth 3 -type f -wholename "*/$PKG_NAME/Makefile")

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

		local NEW_VER=$(echo $PKG_TAG | sed -E 's/[^0-9]+/\./g; s/^\.|\.\$//g')
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
