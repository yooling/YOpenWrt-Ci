#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
#
# 移植自 laipeng668/openwrt-ci-roc 的 Roc-script.sh：
#   1) 按需拉包：先读 Config/$WRT_CONFIG.txt + Config/GENERAL.txt，配置里没选中的包整段跳过
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
#自包含清单架构：Config/<配置>.txt 已经是完整清单，GENERAL.txt 是共用基座。
#★顺序是「机型配置 → GENERAL.txt」，GENERAL 在后 → 同一 key 由 GENERAL 说了算。
#  所以机型层写的 =n 压不住 GENERAL 里的 =y，反过来 GENERAL 的 =y 会盖掉机型的 =n。
#  （此前的注释写反了，害得 ZNM2 的五个 =n 以为生效实则没生效；已连同 GENERAL.txt 一起
#   改掉解决 —— 详见 GENERAL.txt 的「为什么这里越来越短」一节。）
#本文件的扫描结果只用于决定「要不要 clone 某个第三方包源」，真正生成 .config 的合并在
#WRT-CORE.yml 的 Custom Settings 步骤，那里的 cat 顺序同样是机型在前、GENERAL 在后。
#（早期还有一层 Config/*-Override.txt 按设备关键词自动追加，现已取消 ——
# 亚瑟要出 WiFi 与 noWiFi 两份，Override 只认设备名分辨不了形态，见 Settings.sh 注释。）
WRT_CONFIG_FILES=()
if [ -n "${WRT_CONFIG:-}" ] && [ -f "$WORKSPACE/Config/$WRT_CONFIG.txt" ]; then
	WRT_CONFIG_FILES+=("$WORKSPACE/Config/$WRT_CONFIG.txt")
fi
if [ -f "$WORKSPACE/Config/GENERAL.txt" ]; then
	WRT_CONFIG_FILES+=("$WORKSPACE/Config/GENERAL.txt")
fi
#★最终裁决层（PRIVATE）也必须扫进来，否则会出「包选了却拉不到」的怪事：
#  在 PRIVATE 里写了 CONFIG_PACKAGE_xxx=y 想装某个第三方插件，而本脚本没扫这个文件，
#  就判定「配置里没选中」而跳过 clone —— 后面 defconfig 时这个包根本不存在，
#  轻则静默装不上，重则在 package/install 阶段报 unable to select packages 中断编译。
#下面的顺序必须与 Settings.sh / WRT-CORE.yml 里 .config 的合并顺序一致
#（越靠后优先级越高）：机型 → GENERAL → PRIVATE.txt（通用）→ PRIVATE-<配置>.txt（特定）。
#PRIVATE-<配置>.txt 排最后，是为了让「针对某一台的定夺」能压过「对所有台的统一设定」。
if [ -f "$WORKSPACE/Config/PRIVATE.txt" ]; then
	WRT_CONFIG_FILES+=("$WORKSPACE/Config/PRIVATE.txt")
fi
if [ -n "${WRT_CONFIG:-}" ] && [ -f "$WORKSPACE/Config/PRIVATE-$WRT_CONFIG.txt" ]; then
	WRT_CONFIG_FILES+=("$WORKSPACE/Config/PRIVATE-$WRT_CONFIG.txt")
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
		echo "skip $PKG_NAME: not selected in Config/$WRT_CONFIG.txt or Config/GENERAL.txt"
	fi
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

UPDATE_PACKAGE_OPT "luci-app-tailscale" "asvow/luci-app-tailscale" "main"

#UPDATE_PACKAGE_OPT "athena-led" "unraveloop/JDC-AX6600-Athena-LED-Controller" "main"
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
#这些包在 GENERAL.txt 里以各自的名字出现，按 "viking" 匹配不到，必须无条件拉取。
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
