#!/bin/bash
# SPDX-License-Identifier: MIT
#
# USB 随身WiFi 自动 WAN —— 把运行时脚本注入固件 rootfs
#
# 做什么：
#   往 <buildroot>/files/ 写入一组脚本。OpenWrt 打包时会把 $(TOPDIR)/files 叠加到
#   根文件系统（见 package/Makefile 的 prepare_rootfs 调用），于是固件里就带上了
#   「USB 口插入随身WiFi 自动建 WAN」的能力。
#
# 运行时行为：
#   插入 → 识别 USB 网卡 → 创建/对齐 network.usbwan（proto dhcp）→ 加入防火墙 wan 区 → ifup
#   拔出 → 防抖后 ifdown，**保留全部配置**，下次插入直接 ifup（不写 flash、秒级恢复）
#
# 由 Scripts/Handles.sh 调用（那时工作目录是 <buildroot>/package）。
# 手动单独跑也可以：Scripts/USB-WAN.sh [buildroot路径]

set -u

# ---------------------------------------------------------------- 定位 buildroot
BUILDROOT=""
for c in "${1:-}" "$PWD" "$PWD/.." "${GITHUB_WORKSPACE:-}/wrt"; do
	[ -n "$c" ] || continue
	if [ -f "$c/include/toplevel.mk" ]; then
		BUILDROOT="$(cd "$c" && pwd)"
		break
	fi
done

if [ -z "$BUILDROOT" ]; then
	echo "USB-WAN: 找不到 OpenWrt 构建根目录（缺 include/toplevel.mk），跳过注入" >&2
	exit 0
fi

FILES="$BUILDROOT/files"
echo "USB-WAN: 注入到 $FILES"

mkdir -p "$FILES/usr/sbin" \
         "$FILES/etc/config" \
         "$FILES/etc/uci-defaults" \
         "$FILES/etc/hotplug.d/net" \
         "$FILES/etc/init.d"

# ---------------------------------------------------------------- 默认配置
cat > "$FILES/etc/config/usbwan" <<'USBWAN_EOF'
# USB 随身WiFi 自动 WAN 配置
# 改完执行：/etc/init.d/usbwan reload

config usbwan 'global'
	# 总开关，0 = 完全停用自动建 WAN
	option enabled '1'

	# 建出来的逻辑接口名（防火墙、路由都看这个名字）
	option ifname 'usbwan'

	# 开机预置时先绑到这个设备名，让 netifd 在设备一出现就能自动 ifup。
	# 常见值：usb0（RNDIS/CDC-ECM）、wwan0（CDC-NCM/QMI）、eth1（老式 CDC-ECM）。
	# 猜错也没关系，hotplug 会按实际设备名纠正。
	option device_default 'usb0'

	# 路由 metric，越小越优先。
	# 想让随身WiFi 优先于有线 WAN，把它调得比有线 WAN 更小（例如 1），
	# 或者反过来给有线 wan 设 option metric '20'。
	option metric '10'

	# 拔出后的防抖秒数。随身WiFi 掉电重连、modeswitch 重新枚举时会先消失再出现，
	# 立即 ifdown 会造成接口无谓抖动。
	option debounce '3'

	# 归属的防火墙 zone（通常就是 wan，自带 masquerade）
	option firewall_zone 'wan'

	# 发给随身WiFi DHCP 的主机名，留空则不发送
	option dhcp_hostname ''

	# USB 白名单，写 idVendor:idProduct，空格分隔（如 '12d1:155e 2c7c:0125'）。
	# 留空 = 接受任何 USB 网卡。装了多个 USB 网卡、只想让随身WiFi 生效时很有用。
	option usbid_allow ''

	# 设备名黑名单前缀，空格分隔（如 'eth1' 用来排除某个 USB 有线网卡）。留空 = 不排除
	option ifname_deny ''

	# 是否写 /tmp/usbwan.log（tmpfs，不磨损 flash）
	option log '1'
USBWAN_EOF

# ---------------------------------------------------------------- 引擎
cat > "$FILES/usr/sbin/usbwan" <<'USBWAN_EOF'
#!/bin/sh
# USB 随身WiFi 自动 WAN —— 引擎
#
# 子命令：
#   add <netdev>      设备插入时调用
#   remove <netdev>   设备拔出时调用（调用方已做延迟防抖）
#   sync              扫描所有 USB 网卡并对齐配置（开机时调用）
#   preseed <netdev>  只写配置不做 up（首次启动预置，让 netifd 能自动 ifup）
#   down              仅 ifdown，保留配置
#   status            打印当前状态
#   verify <netdev>   拿到 DHCP 地址后检查是否与 LAN 同网段冲突

CONF=usbwan
TAG=usbwan
LOGFILE=/tmp/usbwan.log
# 仅供本机测试时指向伪造的 sysfs；路由器上不要设这个变量
SYS="${USBWAN_SYSFS:-/sys}"

log() {
	logger -t "$TAG" "$*" 2>/dev/null
	[ "$(uci -q get "$CONF.global.log" 2>/dev/null)" = "0" ] && return 0
	if [ -f "$LOGFILE" ] && [ "$(wc -c < "$LOGFILE" 2>/dev/null || echo 0)" -gt 32768 ]; then
		: > "$LOGFILE"
	fi
	echo "$(date '+%F %T') $*" >> "$LOGFILE" 2>/dev/null
	return 0
}

cfg() {
	local v
	v="$(uci -q get "$CONF.global.$1" 2>/dev/null)"
	[ -n "$v" ] || v="${2:-}"
	echo "$v"
}

WANIF="$(cfg ifname usbwan)"

# 取该 netdev 所属 USB 设备的 vendor:product；不是 USB 设备则返回非 0
usb_ids() {
	local dev="$1" p i=0
	p="$(readlink -f "$SYS/class/net/$dev/device" 2>/dev/null)"
	[ -n "$p" ] || return 1
	while [ -n "$p" ] && [ "$p" != "/" ] && [ "$i" -lt 10 ]; do
		if [ -f "$p/idVendor" ]; then
			printf '%s:%s\n' "$(cat "$p/idVendor" 2>/dev/null)" "$(cat "$p/idProduct" 2>/dev/null)"
			return 0
		fi
		p="${p%/*}"
		i=$((i + 1))
	done
	return 1
}

# 是否是一个可用的 USB 网卡（排除无线、已被网桥收编的）
is_usb_netdev() {
	local dev="$1"
	[ -n "$dev" ] || return 1
	[ -d "$SYS/class/net/$dev" ] || return 1
	[ -e "$SYS/class/net/$dev/wireless" ] && return 1
	[ -e "$SYS/class/net/$dev/master" ] && return 1
	usb_ids "$dev" >/dev/null 2>&1 || return 1
	return 0
}

# 白名单 / 黑名单过滤
dev_allowed() {
	local dev="$1" ids a
	for a in $(cfg ifname_deny); do
		case "$dev" in
			"$a"*) log "$dev 命中 ifname_deny=$a，跳过"; return 1 ;;
		esac
	done

	a="$(cfg usbid_allow)"
	[ -n "$a" ] || return 0

	ids="$(usb_ids "$dev" 2>/dev/null | tr 'A-Z' 'a-z')"
	for a in $(cfg usbid_allow); do
		[ "$(echo "$a" | tr 'A-Z' 'a-z')" = "$ids" ] && return 0
	done
	log "$dev（usb $ids）不在 usbid_allow 白名单内，跳过"
	return 1
}

# 该 netdev 是否已被别的 UCI 接口/设备段占用（避免抢走用户自己配好的口）
# 只用 uci show 枚举，不依赖 /lib/functions.sh 的 config_foreach
dev_owned_by_other() {
	local dev="$1" self="$2" s d

	for s in $(uci -q show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=.*$/\1/p'); do
		[ "$s" = "$self" ] && continue
		d="$(uci -q get "network.$s.device" 2>/dev/null)"
		[ "$d" = "$dev" ] && return 0
		for d in $(uci -q get "network.$s.ports" 2>/dev/null); do
			[ "$d" = "$dev" ] && return 0
		done
	done
	return 1
}

# 只在真的不同时才 set，返回 0 = 有改动（用于判断要不要 commit，避免反复写 flash）
uci_set_if_diff() {
	local cur
	cur="$(uci -q get "$1" 2>/dev/null)"
	[ "$cur" = "$2" ] && return 1
	uci -q set "$1=$2" || return 1
	return 0
}

ensure_network() {
	local dev="$1" hn changed=0

	if [ -z "$(uci -q get "network.$WANIF" 2>/dev/null)" ]; then
		uci -q set "network.$WANIF=interface" || return 1
		changed=1
	fi

	uci_set_if_diff "network.$WANIF.proto" dhcp && changed=1
	uci_set_if_diff "network.$WANIF.device" "$dev" && changed=1
	uci_set_if_diff "network.$WANIF.metric" "$(cfg metric 10)" && changed=1
	uci_set_if_diff "network.$WANIF.defaultroute" 1 && changed=1
	uci_set_if_diff "network.$WANIF.peerdns" 1 && changed=1

	hn="$(cfg dhcp_hostname)"
	[ -n "$hn" ] && { uci_set_if_diff "network.$WANIF.hostname" "$hn" && changed=1; }

	if [ "$changed" = "1" ]; then
		uci -q commit network
		log "network.$WANIF 已更新：device=$dev metric=$(cfg metric 10)"
		return 0
	fi
	return 1
}

ensure_firewall() {
	local zname zs cur
	zname="$(cfg firewall_zone wan)"

	zs="$(uci -q show firewall 2>/dev/null \
		| sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='$zname'\$/\1/p" | head -n 1)"
	if [ -z "$zs" ]; then
		log "未找到防火墙 zone '$zname'，跳过防火墙归属设置"
		return 1
	fi

	cur="$(uci -q get "firewall.$zs.network" 2>/dev/null | tr ' ' '\n' | grep -Fx "$WANIF")"
	[ -n "$cur" ] && return 1

	uci -q add_list "firewall.$zs.network=$WANIF" || return 1
	uci -q commit firewall
	log "已把 $WANIF 加入防火墙 zone '$zname'"
	return 0
}

do_add() {
	local dev="$1"
	[ -n "$dev" ] || return 1
	[ -d "$SYS/class/net/$dev" ] || return 1

	is_usb_netdev "$dev" || return 0
	dev_allowed "$dev" || return 0

	if dev_owned_by_other "$dev" "$WANIF"; then
		log "$dev 已被其它接口占用，跳过"
		return 0
	fi

	ensure_network "$dev"
	ensure_firewall
	ifup "$WANIF" 2>/dev/null
	log "已启用：$dev -> $WANIF"
	return 0
}

do_remove() {
	local dev="$1" other

	# 防抖之后设备又在了 = 只是重新枚举（modeswitch / 掉电重连），忽略
	if [ -d "$SYS/class/net/$dev" ]; then
		log "$dev 已重新出现，取消下线"
		return 0
	fi

	# 还有别的 USB 网卡在，就重新对齐，不要 down
	for other in $(ls "$SYS/class/net" 2>/dev/null); do
		is_usb_netdev "$other" || continue
		dev_allowed "$other" || continue
		dev_owned_by_other "$other" "$WANIF" && continue
		log "$dev 已拔出，但发现 $other，改为重新对齐"
		do_sync
		return 0
	done

	# 只 ifdown，不删配置 —— 下次插入可以直接 ifup，且完全不写 flash
	ifdown "$WANIF" 2>/dev/null
	log "$dev 已拔出：$WANIF 已下线（配置保留，下次插入即刻恢复）"
	return 0
}

do_sync() {
	local dev found=0

	for dev in $(ls "$SYS/class/net" 2>/dev/null); do
		is_usb_netdev "$dev" || continue
		dev_allowed "$dev" || continue
		dev_owned_by_other "$dev" "$WANIF" && continue
		do_add "$dev"
		found=1
	done

	if [ "$found" = "0" ]; then
		[ -n "$(uci -q get "network.$WANIF" 2>/dev/null)" ] && ifdown "$WANIF" 2>/dev/null
		log "未发现可用的 USB 网卡，$WANIF 保持下线"
	fi
	return 0
}

do_preseed() {
	local dev="${1:-usb0}"
	ensure_network "$dev"
	ensure_firewall
	log "预置完成：$WANIF -> $dev（设备出现时 netifd 会自动 ifup）"
	return 0
}

do_down() {
	ifdown "$WANIF" 2>/dev/null
	log "$WANIF 已下线（配置保留）"
	return 0
}

# 拿到 DHCP 地址后检查是否与 LAN 撞网段 —— 这是随身WiFi 最常见的翻车点
do_verify() {
	local i=0 wan_cidr wan_gw lan_ip w3 l3

	while [ "$i" -lt 20 ]; do
		wan_cidr="$(ip -4 -o addr show dev "$WANIF" 2>/dev/null | awk '{print $4; exit}')"
		[ -n "$wan_cidr" ] && break
		sleep 1
		i=$((i + 1))
	done

	if [ -z "$wan_cidr" ]; then
		log "verify：$WANIF 未取得 IPv4 地址（随身WiFi 可能还在拨号）"
		return 1
	fi

	wan_gw="$(ip -4 route show dev "$WANIF" 2>/dev/null | awk '/^default/{print $3; exit}')"
	lan_ip="$(uci -q get network.lan.ipaddr 2>/dev/null)"
	[ -n "$lan_ip" ] || lan_ip="$(ip -4 -o addr show dev br-lan 2>/dev/null | awk '{print $4; exit}' | cut -d/ -f1)"
	[ -n "$lan_ip" ] || return 0

	w3="$(echo "${wan_gw:-${wan_cidr%%/*}}" | cut -d. -f1-3)"
	l3="$(echo "$lan_ip" | cut -d. -f1-3)"

	if [ -n "$w3" ] && [ "$w3" = "$l3" ]; then
		log "警告：$WANIF 网关 ${wan_gw:-$wan_cidr} 与 LAN $lan_ip 同网段（$w3.x），路由会冲突、大概率上不了网。请把随身WiFi 的内网网段或路由器 LAN 改到不同网段"
		logger -t "$TAG" -p user.warn "USB WAN 与 LAN 同网段（$w3.x），可能无法上网"
	fi
	return 0
}

do_status() {
	local dev
	echo "接口名      : $WANIF"
	echo "当前 device : $(uci -q get "network.$WANIF.device" 2>/dev/null)"
	echo "metric      : $(cfg metric 10)"
	echo "防火墙 zone : $(cfg firewall_zone wan)"
	echo "预置 device : $(cfg device_default usb0)"
	echo "USB 网卡："
	for dev in $(ls "$SYS/class/net" 2>/dev/null); do
		is_usb_netdev "$dev" || continue
		printf '  %-10s usb %-10s %s\n' "$dev" "$(usb_ids "$dev" 2>/dev/null)" \
			"$([ -n "$(ip -4 -o addr show dev "$dev" 2>/dev/null)" ] && echo up || echo down)"
	done
	echo "接口地址："
	ip -4 -o addr show dev "$WANIF" 2>/dev/null | sed 's/^/  /'
	return 0
}

case "$1" in
	status)
		do_status
		;;
	*)
		if [ "$(cfg enabled 1)" = "0" ]; then
			log "usbwan 已停用（$CONF.global.enabled=0）"
			exit 0
		fi
		case "$1" in
			add)     do_add "$2" ;;
			remove)  do_remove "$2" ;;
			sync)    do_sync ;;
			preseed) do_preseed "$2" ;;
			down)    do_down ;;
			verify)  do_verify "$2" ;;
			*)
				echo "用法: usbwan {add|remove|sync|preseed|down|status|verify} [netdev]"
				exit 1
				;;
		esac
		;;
esac

exit 0
USBWAN_EOF

# ---------------------------------------------------------------- netdev 热插拔
cat > "$FILES/etc/hotplug.d/net/40-usbwan" <<'USBWAN_EOF'
#!/bin/sh
# USB 随身WiFi 自动 WAN —— netdev 热插拔入口

[ -x /usr/sbin/usbwan ] || exit 0

# net 事件的设备名：不同 OpenWrt 版本给的变量不一样，逐个兜底
DEV="${DEVICENAME:-${INTERFACE:-}}"
[ -n "$DEV" ] || DEV="$(basename "${DEVPATH:-}")"
[ -n "$DEV" ] || exit 0
[ "$DEV" = "lo" ] && exit 0

DEBOUNCE="$(uci -q get usbwan.global.debounce 2>/dev/null)"
[ -n "$DEBOUNCE" ] || DEBOUNCE=3

case "$ACTION" in
	add)
		if [ -d "/sys/class/net/$DEV" ]; then
			/usr/sbin/usbwan add "$DEV"
			# 等 DHCP 起好，再检查有没有和 LAN 撞网段
			( sleep 8; /usr/sbin/usbwan verify "$DEV" ) >/dev/null 2>&1 &
		else
			# 没解析出有效设备名，退化成全量对齐
			/usr/sbin/usbwan sync
		fi
		;;
	remove)
		# 延迟处理：随身WiFi 掉电重连、modeswitch 重新枚举时会先消失再出现
		( sleep "$DEBOUNCE"; /usr/sbin/usbwan remove "$DEV" ) >/dev/null 2>&1 &
		;;
esac

exit 0
USBWAN_EOF

# ---------------------------------------------------------------- 首次启动预置
cat > "$FILES/etc/uci-defaults/99-usbwan" <<'USBWAN_EOF'
#!/bin/sh
# 首次启动预置 network.usbwan + 防火墙归属。
# 预置之后，只要设备名对得上，netifd 在设备出现时会自己把接口拉起来，
# 连 hotplug 都不用等。

[ -x /usr/sbin/usbwan ] || exit 0

DEF="$(uci -q get usbwan.global.device_default 2>/dev/null)"
[ -n "$DEF" ] || DEF=usb0

/usr/sbin/usbwan preseed "$DEF"

exit 0
USBWAN_EOF

# ---------------------------------------------------------------- init 服务
cat > "$FILES/etc/init.d/usbwan" <<'USBWAN_EOF'
#!/bin/sh /etc/rc.common
# USB 随身WiFi 自动 WAN
#
#   /etc/init.d/usbwan start     对齐一次（开机自动执行）
#   /etc/init.d/usbwan stop      只 ifdown，保留配置
#   /etc/init.d/usbwan reload    重新对齐
#   usbwan status                看当前状态

START=95
STOP=10

start() {
	[ -x /usr/sbin/usbwan ] && /usr/sbin/usbwan sync
}

stop() {
	[ -x /usr/sbin/usbwan ] && /usr/sbin/usbwan down
}

reload() {
	[ -x /usr/sbin/usbwan ] && /usr/sbin/usbwan sync
}
USBWAN_EOF

# ---------------------------------------------------------------- 权限与校验
chmod 0755 "$FILES/usr/sbin/usbwan" \
           "$FILES/etc/uci-defaults/99-usbwan" \
           "$FILES/etc/hotplug.d/net/40-usbwan" \
           "$FILES/etc/init.d/usbwan"
chmod 0644 "$FILES/etc/config/usbwan"

# files/ 是叠加层，不会走 package 安装流程，rc.d 软链要显式补，
# 否则固件刷完还得手动 enable
mkdir -p "$FILES/etc/rc.d"
ln -sf ../init.d/usbwan "$FILES/etc/rc.d/S95usbwan"

RC=0
for f in usr/sbin/usbwan etc/uci-defaults/99-usbwan etc/hotplug.d/net/40-usbwan etc/init.d/usbwan; do
	if sh -n "$FILES/$f" 2>/dev/null; then
		echo "  OK   $f"
	else
		echo "  FAIL $f 语法检查未通过" >&2
		RC=1
	fi
done
echo "  OK   etc/config/usbwan（UCI 配置）"

echo "USB-WAN: 注入完成（$(find "$FILES" -type f | wc -l) 个文件）"
exit $RC
