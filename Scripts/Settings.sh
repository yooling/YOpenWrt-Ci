#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#移除luci-app-attendedsysupgrade
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
#添加编译日期标识
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	#修改WIFI名称
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
	#修改WIFI密码
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
elif [ -f "$WIFI_UC" ]; then
	#修改WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#修改WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

#======================= 配置一致性：拦截 GENERAL.txt 反向覆盖 =======================
#★为什么非要有这一步 —— 这个坑已经真踩过一次，而且踩得很安静：
#  生成 .config 的顺序是「机型配置 → GENERAL.txt」（WRT-CORE.yml 的 Custom Settings 步骤里
#  两条 cat，机型在前、GENERAL 在后），同一个 CONFIG_* key **后出现者胜**。于是 GENERAL 的
#  取值会静默翻掉机型层写的：编译照常成功、日志一条警告都没有，可编出来的固件跟配置写的不一样。
#  实际事故：ZNM2-noWiFi.txt 里 gecoosac / partexp / samba4 / statistics / wolultra 五个 =n
#  全部失效、照样进固件 —— 配置看着只装 7 个 luci 包，实际装了 20 个。
#现在做成硬检查：命中就列清单 + ::error:: 中断，绝不让这种偏差再流到固件里。
#判定范围放宽到「两边都写了同一个 key 但取值不同」而不是只查 =n vs =y ——
#  机型层 =m（想只编包）被 GENERAL 的 =y 顶成进固件，同样是无声的意外，一样要拦。
#三条出路：
#  1) 把这个 key 从 GENERAL.txt 删掉，让它只待在需要的机型配置里 —— 最干净；
#     GENERAL 只该放三份配置一致同意的东西（纪律写在 GENERAL.txt 顶部）。
#  2) 机型配置别写不同值，也就是承认三份配置本来就一致。
#  3) 用最终裁决层 PRIVATE 明确接管（见本文件末尾「最终裁决层」那段）——
#     GENERAL 是共用基座、不想为了一台设备就动它时，这招最省事：
#     冲突 key 只要在 PRIVATE 里显式写了值，本检查就认它是**有意为之**，放行不报错。
DEV_CFG_FILE="$GITHUB_WORKSPACE/Config/$WRT_CONFIG.txt"
GEN_CFG_FILE="$GITHUB_WORKSPACE/Config/GENERAL.txt"
#▲顺序（越靠后追加优先级越高）：先通用、后特定。
#  这样「针对这一台的定夺」才压得住「对所有台的统一设定」—— 跟常见配置系统的
#  「越具体越优先」一致。反过来（通用在后）会让 PRIVATE-ZNM2-noWiFi.txt 里想给 M2
#  单独开的例外，被 PRIVATE.txt 的统一值闷掉，那这一层就失去意义了。
PRIVATE_FILES=()
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	PRIVATE_FILES+=("$GITHUB_WORKSPACE/Config/PRIVATE.txt")
fi
if [ -n "${WRT_CONFIG:-}" ] && [ -f "$GITHUB_WORKSPACE/Config/PRIVATE-$WRT_CONFIG.txt" ]; then
	PRIVATE_FILES+=("$GITHUB_WORKSPACE/Config/PRIVATE-$WRT_CONFIG.txt")
fi
#TEST 系列不走 GENERAL（WRT-CORE.yml 里那条分支只有一次 cat），不存在覆盖问题，跳过。
if [ -n "${WRT_CONFIG:-}" ] && [ -f "$DEV_CFG_FILE" ] && [ -f "$GEN_CFG_FILE" ] \
	&& [[ "${WRT_CONFIG,,}" != *"test"* ]]; then
	DEV_MAP="$(mktemp)"
	GEN_MAP="$(mktemp)"
	PRIV_MAP="$(mktemp)"
	CONFLICT_RAW="$(mktemp)"
	CONFLICT_MAP="$(mktemp)"
	#同一文件里同一个 key 出现多次时后者生效，awk 覆盖赋值天然保留了最后一次
	sed 's/\r$//' "$DEV_CFG_FILE" |
		awk -F= '/^CONFIG_[A-Za-z0-9_.-]+=[ynm]$/{ v[$1]=$2 } END{ for (k in v) print k"="v[k] }' |
		sort -t= -k1,1 > "$DEV_MAP"
	sed 's/\r$//' "$GEN_CFG_FILE" |
		awk -F= '/^CONFIG_[A-Za-z0-9_.-]+=[ynm]$/{ v[$1]=$2 } END{ for (k in v) print k"="v[k] }' |
		sort -t= -k1,1 > "$GEN_MAP"
	#join 取两边都声明过的 key，再筛掉取值相同的（相同则无冲突），输出 key / 机型值 / GENERAL值
	join -t= "$DEV_MAP" "$GEN_MAP" | awk -F= '$2 != $3 { print $1"\t"$2"\t"$3 }' > "$CONFLICT_RAW"
	#最终裁决层：被 PRIVATE 显式写过值的 key，视为「我知道有冲突、就是要这个值」，摘出冲突清单
	ADJUDICATED="$(mktemp)"
	if [ "${#PRIVATE_FILES[@]}" -gt 0 ]; then
		sed 's/\r$//' "${PRIVATE_FILES[@]}" |
			awk -F= '/^CONFIG_[A-Za-z0-9_.-]+=[ynm]$/{ v[$1]=$2 } END{ for (k in v) print k"="v[k] }' |
			sort -t= -k1,1 > "$PRIV_MAP"
		comm -12 <(cut -f1 "$CONFLICT_RAW" | sort -u) <(cut -d= -f1 "$PRIV_MAP" | sort -u) > "$ADJUDICATED"
	else
		: > "$PRIV_MAP"
	fi
	#▲这里不能用经典的 `NR==FNR` 写法：ADJUDICATED 多数情况下是空文件（没用 PRIVATE 层时），
	#  此时处理第二个文件时 NR 与 FNR 会在它的第一行同时等于 1，条件仍然成立，
	#  于是 CONFLICT_RAW 的第一条冲突会被误当成「已接管」而悄悄吞掉 —— 实测过，确实少报一条。
	#  改成比 FILENAME==ARGV[1] 才可靠：第一个文件为空时 awk 根本不会产生记录。
	awk -F'\t' 'FILENAME==ARGV[1]{ ok[$1]=1; next } !($1 in ok)' "$ADJUDICATED" "$CONFLICT_RAW" > "$CONFLICT_MAP"
	rm -f "$DEV_MAP" "$GEN_MAP" "$PRIV_MAP" "$CONFLICT_RAW"

	#被 PRIVATE 接管的冲突：不拦，但要打印出来，免得以后忘了这层还在生效
	if [ -s "$ADJUDICATED" ]; then
		echo "::notice::以下 $(wc -l < "$ADJUDICATED" | tr -d ' ') 个 key 在机型层与 GENERAL.txt 取值不一致，已由最终裁决层 PRIVATE 明确接管，按 PRIVATE 的值生效：$(tr '\n' ' ' < "$ADJUDICATED")"
	fi
	rm -f "$ADJUDICATED"

	CONFLICT_N="$(wc -l < "$CONFLICT_MAP" | tr -d ' ')"
	if [ "$CONFLICT_N" -gt 0 ]; then
		echo "=============================================================="
		echo " 机型配置的取值被 GENERAL.txt 反向覆盖了（编译中止）"
		echo "=============================================================="
		while IFS=$'\t' read -r WRT_KEY DEV_VAL GEN_VAL; do
			echo "  $WRT_KEY"
			echo "      机型层 Config/$WRT_CONFIG.txt : =$DEV_VAL"
			echo "      GENERAL.txt                   : =$GEN_VAL   ← 后加载，这条说了算"
			case "$DEV_VAL" in
				n) echo "      后果：想在机型层关掉，实际照样编进固件。" ;;
				m) echo "      后果：想只编包不进固件，实际被塞进 rootfs。" ;;
				y) echo "      后果：机型层想装，实际按 GENERAL 的 =$GEN_VAL 办。" ;;
			esac
		done < "$CONFLICT_MAP"
		echo "--------------------------------------------------------------"
		echo "为什么：WRT-CORE.yml 里 cat 的顺序是「机型配置 → GENERAL.txt」，"
		echo "        GENERAL 在后，同一 key 后者覆盖前者，机型层压不住它。"
		echo "怎么改（二选一）："
		echo "  1) 把这些 key 从 GENERAL.txt 删掉、只留机型配置 —— 推荐；"
		echo "     GENERAL 只放三份配置一致同意的内容，详见 GENERAL.txt 顶部说明。"
		echo "  2) 机型配置改用与 GENERAL 相同的值，也就是承认三份本来就一致。"
		echo "=============================================================="
		echo "::error::配置冲突：$WRT_CONFIG 里有 $CONFLICT_N 项被 GENERAL.txt 反向覆盖，编译已中止。上面的清单给出了每个 key 的取值对照与修改办法。"
		rm -f "$CONFLICT_MAP"
		exit 1
	fi
	rm -f "$CONFLICT_MAP"
fi

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
#luci-app-<主题>-config：主题的外观自定义页（换登录壁纸 / 头像 / 配色）。
#  2026-10-09 停用：主路由用不上，而且它会往固件里塞图片素材，128MB NAND 的 M2 省不起。
#  主题本体照常生效，只是少一个「外观设置」菜单项。
#  恢复：把下面这行取消注释。
#echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#设备专属覆盖：本仓库已不使用 —— 配置改为「一台设备/一种形态一份自包含清单」
#（Config/JDCloud-WiFi.txt、JDCloud-noWiFi.txt、ZNM2-noWiFi.txt）。
#原先是 Config/*-Override.txt 按设备关键词（JDCloud / ZNM2）自动匹配、追加到 .config 末尾。
#取消的原因：亚瑟要出 WiFi 与 noWiFi 两份，而 Override 只认设备名（两台都命中 JDCloud），
#没法区分形态；自包含清单天然没有这个问题，也不必再维护「通用层 + 减法」两层。
#如果以后又想回到覆盖机制：把下面那段恢复即可（Packages.sh 里有对应的按需拉包逻辑）。
#if [ -n "$(sed -n 's/^CONFIG_TARGET_DEVICE_.*_DEVICE_\([A-Za-z0-9_-]\{1,\}\)=y[[:space:]]*$/\1/p' ./.config 2>/dev/null)" ]; then
#	...（原 Override 遍历逻辑，见 git 历史）
#fi

#======================= 最终裁决层（PRIVATE）=======================
#★这是整条 .config 合并链上**最后一个**追加层，所以它说了算，谁也覆盖不了它：
#    机型配置 → GENERAL.txt → Settings.sh 注入(luci/主题) → ath11k/NSS 档位裁定
#    → 全局 PRIVATE.txt → 按配置 PRIVATE-<配置>.txt → make defconfig
#  ▲注意两级 PRIVATE 的先后：**通用在前、特定在后**（越具体越优先）。
#    上面 PRIVATE_FILES 的追加顺序就是这个，别照抄某些上游写法把全局排在特定之后 ——
#    那样「给某一台设备单独开的例外」会被统一设定闷掉，这一层就白设了。
#  （make defconfig 之后还有一层依赖求解，它会补齐依赖、仲裁互斥，那是另一回事。）
#用它来解决「GENERAL 是共用基座、不想为了一台设备就动它，但这台设备偏偏要例外」的问题：
#  遇到 GENERAL 顶着某个值不放时，不必去改 GENERAL（改了会波及三份配置），
#  只要在自己那份 PRIVATE 里写一行就行，保证最终结果一定是你想要的。
#  典型用法：Config/PRIVATE-ZNM2-noWiFi.txt 里写 CONFIG_PACKAGE_xxx=n 给 M2 单独关掉某个包。
#两级，都存在时**按配置的那份最后追加、优先级更高**：
#  Config/PRIVATE-<配置名>.txt  只对 WRT_CONFIG 指定的那一份配置生效（推荐用这个）
#  Config/PRIVATE.txt           对所有配置生效
#两级都是 [ -f ] 守卫：文件不存在就整段跳过，零成本，仓库里不放这些文件完全不影响正常编译。
#注意：用了 PRIVATE 接管冲突时，上面的配置一致性检查会打一条 ::notice:: 说明哪些 key 被接管，
#      方便日后追溯「为什么这台设备的固件跟机型配置写的不一样」。
for PRIVATE_FILE in "${PRIVATE_FILES[@]}"; do
	echo "Applying final overrides from $(basename "$PRIVATE_FILE")..."
	cat "$PRIVATE_FILE" >> ./.config
done

#高通平台参数统一裁定（ath11k 内存档位 + NSS 固件版本）
#
#为什么这些项不写在 Config/*.txt：这两个都是 Kconfig 的 choice，同一时刻只能有一个 =y。
#放在这里按「配置名是否 noWiFi」裁定，好处是：
#  1) 新增配置不用记得同时改档位，跟着命名走就行；
#  2) 两份配置互不干扰 —— 各自独立 .config，天然不会出现 choice 多选。
#（早期版本一份配置编多台设备、靠 Override 区分，那时两份 Override 会各写一个 =y 造成
#  choice 多选，才必须集中到这个脚本里收口。现在一配置一设备，这个坑已经不存在，
#  集中裁定保留下来只是为了让档位跟配置名挂钩、少一处要改的地方。）
#
#两条源码线的实现差异（本次踩坑点）：
#  LibWrt(6.12)：ath.mk 里是真正的 choice —— ATH11K_MEM_PROFILE_1G/512M/256M 三选一；
#                NSS 固件版本在 nss-packages feed 的 firmware/nss-firmware/Makefile 里，
#                也是 choice —— 11_4/12_1/12_2/12_5 四选一。
#  VIKINGYFY/immortalwrt(6.18)：两个 choice 都不存在。ath11k 只在 ATH11K_NSS_SUPPORT=y 时
#                由 ath.mk 硬写 ATH11K_MEM_PROFILE_512M；固件版本符号干脆没有。
#                也就是说 6.18 线上这两项用户改不了，写进 .config 会被静默忽略（不报错）。
#判据：用 ath.mk 里有没有 ATH11K_MEM_PROFILE_1G 来识别「这是 LibWrt 那条有 choice 的线」。
if [ -f "./package/kernel/mac80211/ath.mk" ] && grep -q "ATH11K_MEM_PROFILE_1G" ./package/kernel/mac80211/ath.mk; then
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		ATH11K_MEM_KEEP="512M"
		NSS_FW_KEEP="11_4"
	else
		ATH11K_MEM_KEEP="1G"
		NSS_FW_KEEP="12_5"
	fi

	#ath11k 内存档位：带 WiFi 用 1G（亚瑟硬改），无 WiFi 用 512M（ath11k 不工作，不该占内存）
	sed -i '/^CONFIG_ATH11K_MEM_PROFILE_/d; /^# CONFIG_ATH11K_MEM_PROFILE_.* is not set$/d' ./.config
	for ATH_MEM in 1G 512M 256M; do
		if [ "$ATH_MEM" = "$ATH11K_MEM_KEEP" ]; then
			echo "CONFIG_ATH11K_MEM_PROFILE_$ATH_MEM=y" >> ./.config
		else
			echo "# CONFIG_ATH11K_MEM_PROFILE_$ATH_MEM is not set" >> ./.config
		fi
	done

	#NSS 固件版本：带 WiFi 用 12.5（新），无 WiFi 用 11.4（保留 mesh，且是上游默认值）
	sed -i '/^CONFIG_NSS_FIRMWARE_VERSION_/d; /^# CONFIG_NSS_FIRMWARE_VERSION_.* is not set$/d' ./.config
	for NSS_FW in 11_4 12_1 12_2 12_5; do
		if [ "$NSS_FW" = "$NSS_FW_KEEP" ]; then
			echo "CONFIG_NSS_FIRMWARE_VERSION_$NSS_FW=y" >> ./.config
		else
			echo "# CONFIG_NSS_FIRMWARE_VERSION_$NSS_FW is not set" >> ./.config
		fi
	done

	echo "qualcommax params resolved: ath11k mem=$ATH11K_MEM_KEEP, nss firmware=$NSS_FW_KEEP"
fi

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#======================= 命名规则（固定写法，别自创）=======================
#带 WiFi 的配置一律以 -WiFi 结尾，无 WiFi 的一律以 -noWiFi 结尾：
#    JDCloud-WiFi / JDCloud-noWiFi / ZNM2-noWiFi
#▲WiFi 的大小写要统一写 WiFi（i 小写），不要写 WIFI / Wifi / wiFi —— 一是和 noWiFi
#  保持一致的驼峰观感，二是 Linux 大小写敏感，配置名/工作流名/WRT_CONFIG 三处必须
#  完全一致，写歪一个字母就是「找不到配置文件」。
#为什么必须固定：下面判断「是否有 WiFi」靠的是配置名小写后同时含 wifi 与 no，
#写成 WIFI-NO / wifi / NoWifi / -nowifi 都可能让判定悄悄失效 —— 判错的后果是
#固件文件名带上错误的 WIFI 标记，而且 dtsi 不会切成 nowifi 版（NSS 白占一大块内存），
#不报错、只是产物不对，最难查。所以这里主动校验一次。
#TEST 是只输出 .config 的调试配置，不参与这条规则。
case "$WRT_CONFIG" in
	TEST) ;;
	*-WiFi|*-noWiFi) ;;
	*)
		echo "::warning::配置名 '$WRT_CONFIG' 不符合命名规则：带 WiFi 用 -WiFi 结尾、无 WiFi 用 -noWiFi 结尾（如 JDCloud-WiFi / JDCloud-noWiFi）。注意是 WiFi 不是 WIFI。当前会按「带 WiFi」处理，若实际是无 WiFi 配置，dtsi 不会切换、固件文件名标记也会错。"
		;;
esac

#无WIFI配置标志
#WRT-CORE 里 WRT_WIFI 的初值是 none，这里给一个确定值：
#配置名以 -noWiFi 结尾 → wifi-no，其余一律 wifi-yes。
if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
	echo "WRT_WIFI=wifi-no" >> $GITHUB_ENV
else
	echo "WRT_WIFI=wifi-yes" >> $GITHUB_ENV
fi

#高通平台调整
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#当前配置里实际要编的设备（可能不止一台），后面按设备名做定向调整
	WRT_DEVICES="$(sed -n 's/^CONFIG_TARGET_DEVICE_.*_DEVICE_\([A-Za-z0-9_-]\{1,\}\)=y[[:space:]]*$/\1/p' ./.config 2>/dev/null)"

	#无WIFI配置调整Q6大小
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"

		#======================= 无 WiFi 兜底：清掉无线配置的生成源 =======================
		#背景：只关 ath11k 驱动是不够的 —— target 里那个 ipq6018-nowifi.dtsi 名叫 nowifi，
		#  实际只改了 Q6 预留内存大小（16MB），第 3 行就是 #include "ipq6018.dtsi"，
		#  WiFi 设备节点原样保留。于是 /etc/board.json 里仍有 wlan 段，wifi-scripts
		#  照样把 /etc/config/wireless 生成出来，LuCI 的「网络 → 无线」菜单因此一直存在，
		#  点进去是 radio0 / radio1 两行「设备未激活」的死条目。
		#  菜单的显示条件正是「/etc/config/wireless 里存在 wifi-device 段」
		#  （luci-mod-network 菜单定义：depends.uci → wireless @wifi-device），
		#  所以掐掉这个文件，菜单自己就没了，不需要改 LuCI 源码。
		#第一道防线在配置层（wpad-openssl=n → hostapd-common → wifi-scripts 一起消失，
		#  连 /sbin/wifi 都不存在）。这里补第二道：万一哪天依赖关系变化、某个包又把
		#  wifi-scripts 拉回来，首启仍然会把残留配置清掉。
		#（base-files 自带的 90-wireless-defaults 不用动：它 source 的
		#  20-wireless-defaults 第一句就判断 /etc/config/wireless 是否存在，
		#  它只调整已存在的配置，不是生成者。）
		NOWIFI_UCI="./package/base-files/files/etc/uci-defaults"
		if [ -d "./package/base-files/files/etc" ]; then
			mkdir -p "$NOWIFI_UCI"
			cat > "$NOWIFI_UCI/99-strip-wireless" <<'NOWIFIEOF'
#!/bin/sh
#无 WiFi 机型：清掉可能残留的无线配置，让 LuCI 的「网络 → 无线」菜单消失。
#菜单显示条件 = /etc/config/wireless 里存在 wifi-device 段（luci-mod-network 的菜单定义）。
#本机没有 ath11k 驱动、也不会有 ieee80211 PHY，删掉后不会被重新生成。
[ -f /etc/config/wireless ] && rm -f /etc/config/wireless
#wpad / wifi 的服务脚本若还在，一并停掉（正常已被 wpad-openssl=n 关掉，这里是兜底）
[ -x /etc/init.d/wpad ] && /etc/init.d/wpad disable 2>/dev/null
[ -x /etc/init.d/wifi ] && /etc/init.d/wifi disable 2>/dev/null
rm -f /etc/rc.d/S*wpad /etc/rc.d/S*wifi /etc/rc.d/K*wpad /etc/rc.d/K*wifi 2>/dev/null
exit 0
NOWIFIEOF
			chmod 0755 "$NOWIFI_UCI/99-strip-wireless"
			echo "qualcommax nowifi: injected /etc/uci-defaults/99-strip-wireless!"
		else
			echo "::warning::package/base-files/files/etc 不存在，跳过无WiFi清理脚本注入！"
		fi
	fi
	# JDCloud RE-SS-01 硬改1G内存：ath11k切换完整内存模式（省内存模式仅适用于原厂512M）
	#★必须判断「本配置真的在编亚瑟」—— 只看文件存在的话，编 M2 时也会顺手改掉亚瑟的 dts，
	#  那是同一棵源码树里的文件，改了对本次产物无影响，但语义错误、且容易误导后来人。
	#  另外必须是「硬件真硬改过 1G」的设备才该改；两种形态（WiFi / noWiFi）都是同一块板子，
	#  所以只要配置里出了 jdcloud_re-ss-01 就改，不区分 WiFi。
	if printf '%s\n' "$WRT_DEVICES" | grep -qx 'jdcloud_re-ss-01'; then
		if [ -f "$DTS_PATH/ipq6000-re-ss-01.dts" ]; then
			sed -i 's/qcom,ath11k-fw-memory-mode = <1>/qcom,ath11k-fw-memory-mode = <0>/' "$DTS_PATH/ipq6000-re-ss-01.dts"
			echo "jdcloud re-ss-01 set ath11k fw memory-mode to 0 (1G RAM) done!"
		fi
		#noWiFi 形态下 ath11k 不工作，内存模式改了也不影响；保持统一处理，避免两种形态
		#出现「同一块板子、dts 却不同」的隐性差异。
	fi

	# ---- IPQ 专属调参（思路来自 laipeng668/openwrt-ci-roc 的 Roc-script.sh）----
	# 这两项在原仓库里都是注释掉的"手动旋钮"，这里改成由机型配置里的标记驱动，
	# 好处是调参跟着机型配置走，不用每次改脚本。标记写法（行首 # @ 开头）：
	#   # @WRT_Q6_REGION=0x02000000   —— NSS 预留内存改成 32MB
	#   # @WRT_CPU_UV=950000          —— 1.5GHz 档电压改成 0.95V
	# 两个标记都默认不写 = 不生效；找不到对应文件/匹配行也只是跳过，不会让构建失败。

	WRT_CFG_FILE="$GITHUB_WORKSPACE/Config/$WRT_CONFIG.txt"

	# NSS q6_region 内存预留：ipq6018.dtsi 默认 85MB，ipq6018-512m.dtsi 默认 55MB。
	# 带 WiFi 至少留 54MB；无 WiFi 机型可以调小，512MB 内存的小机器收益明显。
	# 可选值：0x01000000=16MB / 0x02000000=32MB / 0x04000000=64MB / 0x06000000=96MB
	if [ -f "$WRT_CFG_FILE" ]; then
		Q6_REGION="$(grep -m 1 -oP '^#\s*@WRT_Q6_REGION=\K0[xX][0-9a-fA-F]+' "$WRT_CFG_FILE" 2>/dev/null)"
	fi
	if [ -n "${Q6_REGION:-}" ]; then
		Q6_FILES="$(find ./target/linux/qualcommax -type f -name 'ipq6018*.dtsi' 2>/dev/null)"
		if [ -n "$Q6_FILES" ]; then
			echo "$Q6_FILES" | while read -r Q6_FILE; do
				if sed -i "s/reg = <0x0 0x4ab00000 0x0 0x[0-9a-fA-F]\+>/reg = <0x0 0x4ab00000 0x0 $Q6_REGION>/" "$Q6_FILE"; then
					echo "q6_region set to $Q6_REGION in $Q6_FILE"
				fi
			done
		else
			echo "q6_region: no ipq6018*.dtsi found, skipped!"
		fi
	fi

	# 1.5GHz 频率档电压：默认 0.9375V，过低可能不稳定，过高增加发热功耗。
	# 只处理 qualcommax 补丁里 opp-microvolt = <937500> 的那一行。
	if [ -f "$WRT_CFG_FILE" ]; then
		CPU_UV="$(grep -m 1 -oP '^#\s*@WRT_CPU_UV=\K[0-9]+' "$WRT_CFG_FILE" 2>/dev/null)"
	fi
	if [ -n "${CPU_UV:-}" ]; then
		UV_FILES="$(grep -rl 'opp-microvolt = <937500>' ./target/linux/qualcommax/patches-*/ 2>/dev/null)"
		if [ -n "$UV_FILES" ]; then
			echo "$UV_FILES" | while read -r UV_FILE; do
				if sed -i "s/opp-microvolt = <937500>;/opp-microvolt = <$CPU_UV>;/" "$UV_FILE"; then
					echo "cpu 1.5GHz microvolt set to $CPU_UV in $UV_FILE"
				fi
			done
		else
			echo "cpu microvolt: no patch with opp-microvolt 937500 found, skipped!"
		fi
	fi
fi
