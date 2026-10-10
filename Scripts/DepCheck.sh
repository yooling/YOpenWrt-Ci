#!/bin/bash
#依赖预检：在 make defconfig 之后跑，提前找出 apk 阶段才会暴露的"依赖包不存在"。
#
#为什么需要它：
#	源码（VIKINGYFY/immortalwrt）已迁移到 apk 包管理器。.config 里 =y 的包，
#	如果它的运行时依赖在源码树里根本没有对应的包，make defconfig 不会报任何错 ——
#	要等 1.5~3 小时把几百个包全部编完之后，在 package/install 阶段才报：
#		ERROR: unable to select packages: xxx (no such package): required by: yyy
#	然后 make world 直接中断，整次编译白跑，而且编译失败还会导致缓存不保存。
#	本脚本在 defconfig 之后花几秒钟把这类问题一次全列出来。
#
#	已经踩过的实例：
#		luci-app-tailscale    -> tailscale / python3-email / python3-pkg-resources 不存在
#		luci-app-passwall2    -> v2ray-geoip / v2ray-geosite 已被生态改名成 v2ray-geodata
#		luci-app-mosdns       -> 同上
#
#运行位置：源码根目录（WRT-CORE 里是 cd ./wrt/ 之后调用）
#退出码：永远 0 —— 预检只告警，绝不阻断编译（误报毁掉一次完整编译的代价远高于漏报）
#依赖数据来源：tmp/.packageinfo（scripts/package-metadata.pl 生成，make defconfig 会产出）
#	luci.mk 里有 DEPENDS:=$(LUCI_DEPENDS)，所以 luci 包的 LUCI_DEPENDS 也在里面，不用另外解析 Makefile

set +e

PKGINFO="tmp/.packageinfo"
CONFIG=".config"
#忽略清单：Config/DepCheck-ignore.txt，每行一个「认了无害」的依赖名，命中就不报警。
#用途与准入标准见那个文件头部的说明 —— 只收「名字对不上但编译验证过不会中断」的，
#mwan3 那种会在 package/install 炸的不许放进来。
#CI 里本脚本是在 ./wrt（源码根）下跑的，仓库根在 $GITHUB_WORKSPACE；本地调试时退回上一级。
IGNORE_FILE="${GITHUB_WORKSPACE:-..}/Config/DepCheck-ignore.txt"
[ -f "$IGNORE_FILE" ] || IGNORE_FILE=""

if [ ! -f "$CONFIG" ]; then
	echo "::warning::DepCheck: 当前目录没有 .config，跳过依赖预检"
	exit 0
fi

#临时目录必须用【相对路径】：Windows 的 Git Bash 下 mktemp -d 返回的是
#	C:\Users\ADMINI~1\AppData\Local\Temp\tmp.XXXX
#这种反斜杠路径传给 awk 会被当成转义序列（\U \A \L \T 直接被吃掉）导致文件打不开，
#结果就是"检查了但一条都没报"。用相对路径在 Windows / Linux CI 上都安全。
WORK=".depcheck.$$"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

#---------- 1. .config 里被选中的包 ----------
#形如 CONFIG_PACKAGE_luci-app-nikki=y / =m
#排除带下划线的项：那些是包自带的配置子项（如 ..._Basic_Core_All），不是包名
grep -oE '^CONFIG_PACKAGE_[^=_]+=[ym]' "$CONFIG" | sed -e 's/^CONFIG_PACKAGE_//' -e 's/=[ym]$//' | sort -u > "$WORK/selected"
SELECTED=$(wc -l < "$WORK/selected")

#---------- 2. "可用包"集合 ----------
#权威来源：tmp/.packageinfo 的 Package: 字段（枚举树里所有包，含一个 Makefile 定义多个包的
#情形，比如 kmod-* 全在 package/kernel/linux/modules/Makefile 里，按目录名找会漏）。
#Provides: 是虚拟提供名 —— apk 允许"别的包提供这个名字"，也算可用。
#只有 packageinfo 不存在时才退回"含 Makefile 的目录名"，那种方式准确度较差（会误报 kmod-*）。
if [ -f "$PKGINFO" ]; then
	awk '
		/^Package: /  { print $2 }
		#▲Provides 的两种坑，原写法都会漏：
		#  1) "Provides: wget-any=2024.10" 带版本号 —— 不去 =version 就永远匹配不上
		#     "wget-any"，明明 uclient-fetch 提供了它，还是报缺失（CI 上实测误报）。
		#  2) "Provides: a,b" 逗号分隔多个 —— 原来只删逗号不切分，"a,b" 被粘成 "ab"。
		/^Provides: / {
			sub(/^Provides: /, "")
			gsub(/,/, " ")
			n=split($0, arr, /[[:space:]]+/)
			for (i=1; i<=n; i++) {
				if (arr[i] == "") continue
				v=arr[i]; sub(/=.*$/, "", v)
				if (v == "") continue
				print v
				#▲虚拟包：OpenWrt 的写法带 @ 前缀（uclient-fetch 的 PROVIDES:=@wget-any）。
				#  而依赖方常写成 +wget-any（不带 @），两边对不上就会误报"不存在"。
				#  所以 @name 额外登记一份 name。典型误报：apk-openssl -> wget-any
				#  （apk 要调外部 wget 下载包，靠这个虚拟包找一个 wget 实现）。
				if (v ~ /^@/) print substr(v, 2)
			}
		}
	' "$PKGINFO" | sort -u > "$WORK/avail"
	AVAIL_SRC="$PKGINFO"
else
	find package feeds -mindepth 2 -maxdepth 6 -name Makefile -printf '%h\n' 2>/dev/null | sed 's|.*/||' | sort -u > "$WORK/avail"
	AVAIL_SRC="Makefile 目录名（未找到 $PKGINFO，准确度较低，kmod-* 之类可能误报）"
fi
AVAIL=$(wc -l < "$WORK/avail")

#---------- 2b. 选中的包【本身】在不在源码树里 ----------
#这一条是 mwan3 那次编译失败逼出来的：Config 里写了 CONFIG_PACKAGE_mwan3=y，
#但源码树里根本没有 mwan3 这个包 —— Kconfig 没有这个符号，defconfig 会静默丢掉这一行，
#于是 mwan3 不会被编译、也进不了 apk 索引，最后依赖它的 luci-app-mwan3 在
#package/install 阶段炸 "ERROR: unable to select packages: mwan3 (no such package)"。
#上面第 4 步只比对「依赖在不在」，查不出「包自己失踪了」，所以这里补一道。
awk -v avail="$WORK/avail" '
	BEGIN { while ((getline l < avail) > 0) have[l]=1 }
	{ if (!($0 in have)) print $0 }
' "$WORK/selected" > "$WORK/ghost"
GHOST=$(wc -l < "$WORK/ghost")

#---------- 3. 依赖列表 ----------
#格式统一为 "包名<TAB>依赖token"，后面再统一清洗
: > "$WORK/deps_raw"

if [ -f "$PKGINFO" ]; then
	awk -v OFS='\t' '
		/^Package: / { pkg=$2; next }
		/^(Depends|Extra-Depends): / {
			sub(/^(Depends|Extra-Depends): /, "")
			#▲必须按【空格】也切：.packageinfo 里 Depends 多数写成 "+libc +mwan3"
			#  （空格分隔、不带逗号）。原来只按逗号切，整行当一个 token，
			#  到清洗那步又被 "只留第一个词" 截一刀 —— 实际只检查了第一个依赖，
			#  后面的一律看不到（mwan3 就是这么漏掉的）。
			#  括号里的版本约束先整段去掉，免得 ">=1.2" 被当成包名误报。
			gsub(/\([^)]*\)/, "")
			gsub(/,/, " ")
			n=split($0, arr, /[[:space:]]+/)
			for (i=1; i<=n; i++) if (arr[i] != "") print pkg, arr[i]
		}
	' "$PKGINFO" >> "$WORK/deps_raw"
else
	#兜底：直接解析选中包目录下的 Makefile。
	#必须自己拼 \ 续行 —— LUCI_DEPENDS 通常写成多行，只 grep 单行会把
	#第二行之后的依赖（本例里的 v2ray-geoip）整个漏掉。
	find package feeds -mindepth 2 -maxdepth 6 -name Makefile 2>/dev/null > "$WORK/mkfiles"
	awk -v sel="$WORK/selected" '
		BEGIN { while ((getline l < sel) > 0) want[l]=1 }
		{
			n=$0; sub(/\/Makefile$/, "", n); sub(/.*\//, "", n)
			if (n in want) print
		}
	' "$WORK/mkfiles" > "$WORK/mk_sel"
	if [ -s "$WORK/mk_sel" ]; then
		xargs awk -v sel="$WORK/selected" '
			BEGIN { while ((getline l < sel) > 0) want[l]=1 }
			FNR==1 {
				n=FILENAME; sub(/\/Makefile$/, "", n); sub(/.*\//, "", n)
				active=(n in want); buf=""; cont=0
			}
			!active { next }
			{
				line=$0
				sub(/[ \t]+$/, "", line)
				if (line ~ /\\$/) { sub(/\\$/, "", line); buf = buf " " line; cont=1; next }
				if (cont) { line = buf " " line; buf=""; cont=0 }
				if (line !~ /^[[:space:]]*(LUCI_)?DEPENDS[[:space:]]*[:+]?=/) next
				sub(/^[^=]*=[+]?/, "", line)     #去掉 "  LUCI_DEPENDS:=" / "  DEPENDS+="
				c=split(line, tok, /[ \t]+/)
				for (i=1; i<=c; i++) if (tok[i] != "") print n "\t" tok[i]
			}
		' < "$WORK/mk_sel" >> "$WORK/deps_raw" 2>/dev/null
	fi
fi

#---------- 4. 清洗依赖名并比对 ----------
#依赖 token 的几种常见形态：
#	+tcping           -> tcping
#	+libfoo (>=1.2)   -> libfoo（紧跟的括号项丢弃）
#	+libfoo(<1)       -> libfoo
#	@TARGET_xxx       -> 丢弃（Kconfig 条件，不是包名）
#	+PACKAGE_x:foo    -> foo（条件依赖，取冒号后面）
#	+kmod-xxx         -> kmod-xxx
awk -F'\t' -v avail="$WORK/avail" -v sel="$WORK/selected" -v ign="$IGNORE_FILE" -v work="$WORK" '
	BEGIN {
		while ((getline l < avail) > 0) have[l]=1
		while ((getline l < sel) > 0) want[l]=1
		while (ign != "" && (getline l < ign) > 0) {
			sub(/#.*/, "", l)
			gsub(/^[ \t]+|[ \t]+$/, "", l)
			if (l != "") ignore[l]=1
		}
		#基础库 / 工具链提供、树里没有同名包目录的（packageinfo 里一般都有，这里是兜底防误报）
		split("libc libgcc libm librt libpthread libdl libstdcpp libatomic libxcrypt", b, " ")
		for (i in b) have[b[i]]=1
	}
	{
		pkg=$1
		if (!(pkg in want)) next
		dep=$2
		sub(/^[ \t]+/, "", dep)              #去前导空格（packageinfo 里逗号后带空格）
		sub(/^\+/, "", dep)                  #去 + 前缀
		sub(/[ \t].*$/, "", dep)             #只留第一个词：+libfoo (>=1.2) -> +libfoo
		sub(/\(.*$/, "", dep)                #紧贴写法：+libfoo(<1) -> libfoo
		if (dep ~ /:/) sub(/^.*:/, "", dep)  #条件依赖：+PACKAGE_x:foo -> foo
		if (dep == "" || dep == pkg) next
		if (dep ~ /^@/) next                 #Kconfig 条件，不是包名
		if (dep ~ /^PACKAGE_/) next          #条件依赖前缀
		#▲Kconfig 配置符号：全大写 + 下划线（NSS_DRV_IPV6_ENABLE / NSS_DRV_WIFIOFFLOAD_ENABLE
		#  之类）。.packageinfo 里 "Depends: +NSS_DRV_IPV6_ENABLE" 的含义是「依赖这个配置开关
		#  被打开」，由 Kconfig 的 depends on 处理，**不由包管理器提供** —— 拿它去比对包名
		#  必然查不到。CI 上三条源码线一共误报了 17 条这类，全是 NSS_DRV_*。
		#  OpenWrt 包名一律小写（数字 / 连字符 / 点 / 加号），所以「全大写」判定足够可靠。
		if (dep ~ /^[A-Z][A-Z0-9_]*$/) next
		#忽略清单：命中的直接跳过，只计数，不算缺失
		if (dep in ignore) { IGN++; next }
		if (dep in have) next
		print pkg "\t" dep
	}
	END { print IGN+0 > (work "/ignored") }
' "$WORK/deps_raw" | sort -u > "$WORK/missing"

MISSING=$(wc -l < "$WORK/missing")
IGNORED=$(cat "$WORK/ignored" 2>/dev/null)
IGNORED=${IGNORED:-0}

#---------- 5. 输出 ----------
#说明：只告警不失败。缺失项会同时以 ::error:: 注解输出，GitHub 会把它们收集到
#      Annotations 区和 job 摘要里，不用翻日志也能看到。
echo "==================== 依赖预检（DepCheck） ===================="
echo "选中包 $SELECTED 个 / 可用包 $AVAIL 个（来源：$AVAIL_SRC）"
echo "--------------------------------------------------------------"

if [ "$GHOST" -gt 0 ]; then
	echo "⚠️  其中 $GHOST 个包在源码树里根本不存在（写了也白写，defconfig 会静默丢弃）："
	sed 's/^/      /' "$WORK/ghost"
	echo "   若还有别的包依赖它们，编译会在 package/install 阶段中断。"
	echo "--------------------------------------------------------------"
	while IFS= read -r g; do
		echo "::error::DepCheck: 配置选中了 $g，但源码树里没有这个包（defconfig 会丢弃该行；若有别的包依赖它，package/install 阶段会报 no such package）"
	done < "$WORK/ghost"
fi

if [ "$MISSING" -eq 0 ]; then
	echo "✅ 未发现缺失依赖"
else
	echo "❌ 发现 $MISSING 条缺失依赖（这些包在源码树里不存在）："
	echo "   后果：编完所有包之后，package/install 阶段会报"
	echo "   ERROR: unable to select packages: xxx (no such package)"
	echo "   然后 make world 中断 —— 前面 1.5~3 小时白跑。"
	echo "--------------------------------------------------------------"
	#按包名归拢输出，方便照着改 Config
	awk -F'\t' '{ a[$1] = a[$1] " " $2 } END { for (p in a) printf "  %-32s ->%s\n", p, a[p] }' "$WORK/missing" | sort
	echo "--------------------------------------------------------------"
	echo "处理：在 Config/*.txt 里把这些包设成 =n，或换成源里确实存在的替代包。"
	head -50 "$WORK/missing" | while IFS=$'\t' read -r p d; do
		echo "::error::DepCheck: $p 依赖的 $d 在源码树中不存在，将在 package/install 阶段中断编译"
	done
fi
if [ "$IGNORED" -gt 0 ]; then
	echo "另有 $IGNORED 条命中忽略清单（Config/DepCheck-ignore.txt），已跳过不报警"
fi
echo "==============================================================="

if [ -n "$GITHUB_STEP_SUMMARY" ]; then
	{
		echo "### 依赖预检（DepCheck）"
		echo ""
		echo "- 选中包：**$SELECTED** 个；可用包：**$AVAIL** 个（来源：$AVAIL_SRC）"
		if [ "$GHOST" -gt 0 ]; then
			echo "- ⚠️ 有 **$GHOST** 个选中的包在源码树里不存在（写了也白写，defconfig 会丢弃）："
			sed 's/^/  - /' "$WORK/ghost"
		fi
		if [ "$MISSING" -eq 0 ]; then
			echo "- 结果：✅ 未发现缺失依赖"
		else
			echo "- 结果：❌ **$MISSING** 条缺失依赖"
			echo ""
			echo "| 包 | 缺失的依赖 |"
			echo "|---|---|"
			awk -F'\t' '{ a[$1] = a[$1] " `" $2 "`" } END { for (p in a) printf "| %s |%s |\n", p, a[p] }' "$WORK/missing" | sort
		fi
		if [ "$IGNORED" -gt 0 ]; then
			echo ""
			echo "- 另有 **$IGNORED** 条命中忽略清单（`Config/DepCheck-ignore.txt`），已跳过不报警"
		fi
	} >> "$GITHUB_STEP_SUMMARY"
fi

exit 0
