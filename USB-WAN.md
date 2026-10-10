# USB 随身WiFi 自动 WAN

插上随身WiFi 自动建 WAN 口并接入防火墙；拔掉自动下线。针对京东云亚瑟（RE-SS-01 / AX1800 Pro，IPQ6000）。

## 它做了什么

```
插入 USB
  ├─ 识别是不是 USB 网卡（读 sysfs 里有没有 idVendor，排除无线 / 网桥成员 / 已被别人占用的口）
  ├─ 建 / 对齐 network.usbwan   → proto dhcp, metric 10, defaultroute 1
  ├─ 加入防火墙 wan 区           → 自带 masquerade，LAN 侧可直接上网
  └─ ifup usbwan

拔出 USB（延迟 3 秒确认不是重新枚举）
  └─ ifdown usbwan               → 只下线，配置全保留
```

**为什么保留配置而不是清理：** netifd 的行为是「配置里的 device 出现 → 自动 `interface_set_available(true)` → `interface_set_up()`」（见 `netifd/interface.c` 的 `interface_main_dev_cb`）。所以配置留着，下次插入是**设备一出现就被 netifd 自己拉起来**，比每次重建接口快得多；而且不用反复 `uci commit` 写 flash。清理掉反而每次都要走一遍建段 + 提交 + 防火墙 reload。

## 依赖的内核模块

已经在你仓库的 `Config/GENERAL.txt` 里了，不需要额外加：

| 用途 | 包 |
|---|---|
| RNDIS（多数手机 / 廉价随身WiFi） | `kmod-usb-net-rndis` |
| CDC-ECM | `kmod-usb-net-cdc-ether` |
| CDC-NCM（华为等） | `kmod-usb-net-cdc-ncm`、`kmod-usb-net-huawei-cdc-ncm` |
| CDC-MBIM / QMI | `kmod-usb-net-cdc-mbim`、`kmod-usb-net-qmi-wwan` |
| iPhone 共享 | `kmod-usb-net-ipheth` |
| ZeroCD 切换（插上先当 U 盘的光驱模式） | `usb-modeswitch` + `usb-modeswitch-data` |
| USB 控制器 | `kmod-usb-xhci`、`kmod-usb-dwc3`、`kmod-usb3` |

## 配置

`/etc/config/usbwan`：

| 选项 | 默认 | 说明 |
|---|---|---|
| `enabled` | `1` | 总开关 |
| `ifname` | `usbwan` | 建出来的逻辑接口名 |
| `device_default` | `usb0` | 开机预置时先绑的设备名。猜错也没关系，hotplug 会纠正 |
| `metric` | `10` | **越小越优先**。想让随身WiFi 压过有线 WAN，设成 `1`，或给有线 wan 设 `metric 20` |
| `debounce` | `3` | 拔出后的防抖秒数 |
| `firewall_zone` | `wan` | 归属的防火墙 zone |
| `dhcp_hostname` | 空 | 发给随身WiFi 的 DHCP 主机名 |
| `usbid_allow` | 空 | 白名单，如 `12d1:155e 2c7c:0125`。留空 = 接受任何 USB 网卡 |
| `ifname_deny` | 空 | 设备名前缀黑名单，如 `eth1` |
| `log` | `1` | 写 `/tmp/usbwan.log`（tmpfs，不磨损 flash） |

改完执行 `/etc/init.d/usbwan reload`。

## 常用命令

```sh
usbwan status                 # 看当前状态、识别到的 USB 网卡、接口地址
usbwan sync                   # 手动重新对齐一次
usbwan down                   # 只下线，保留配置
/etc/init.d/usbwan restart    # 重新对齐
logread -e usbwan             # 看日志
cat /tmp/usbwan.log           # 同上，带时间戳
```

## 排错

**1. 插上了但没建接口**
先确认设备被认到了：`lsusb`、`ls /sys/class/net/`、`logread | tail -50`。
如果设备名不在预期（不是 `usb0`），执行 `usbwan sync` 手动对齐一次，再看 `usbwan status`。
如果 `lsusb` 看到的是光驱模式（如 `12d1:1f01`），说明还卡在 ZeroCD，确认 `usb-modeswitch` 已安装。

**2. 接口起来了但上不了网 —— 大概率是同网段冲突**
这是随身WiFi 最常见的坑。很多随身WiFi 内网是 `192.168.0.1/24` 或 `192.168.1.1/24`，而路由器 LAN 默认也是 `192.168.1.1`，两边撞上路由就废了。
脚本会在拿到地址后检查并打警告（`logread -e usbwan` 能看到）。解决办法二选一：
- 改路由器 LAN 到别的网段（`Config` 里的 `WRT_IP`，例如 `192.168.10.1`）
- 进随身WiFi 的 Web 后台把它的内网网段改掉

**3. 想固定用某个随身WiFi，不让别的 USB 网卡抢占**
`usbwan.global.usbid_allow` 填它的 `idVendor:idProduct`（`lsusb` 能看到）。

## 文件清单

由 `Scripts/USB-WAN.sh` 注入到 `<buildroot>/files/`，最终落到固件里：

| 路径 | 作用 |
|---|---|
| `/usr/sbin/usbwan` | 引擎，`add` / `remove` / `sync` / `preseed` / `down` / `status` / `verify` |
| `/etc/hotplug.d/net/40-usbwan` | netdev 热插拔入口（薄封装） |
| `/etc/uci-defaults/99-usbwan` | 首次启动预置 `network.usbwan` + 防火墙归属 |
| `/etc/init.d/usbwan` | 开机对齐（`START=95`）、`stop` 只下线 |
| `/etc/config/usbwan` | 配置 |

调用点在 `Scripts/Handles.sh` 末尾。所有 workflow 都汇入 `WRT-CORE.yml`，所以挂这一处即可。

## 已验证

本地用假 sysfs + 假 `uci`/`ifup`/`ifdown` 跑了 46 项断言（引擎 36 + hotplug 入口 10），全部通过，覆盖：首次插入建接口、重复触发幂等不写 flash、非 USB / 无线 / 网桥成员 / 已被占用设备的跳过、拔出保留配置、重新插入免重建、预置、sync 对齐、白/黑名单、总开关、自定义接口名与 metric。
