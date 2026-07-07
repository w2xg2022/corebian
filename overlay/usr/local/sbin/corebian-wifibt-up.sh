#!/bin/sh
# Corebian —— 开机拉起 UWE5621DS WiFi + 蓝牙
KVER=5.15.196
M=$(dirname "$(find /lib/modules/$KVER -name uwe5621_bsp_sdio.ko 2>/dev/null | head -1)")

# WiFi/BT 内核模块(out-of-tree, 走 insmod 全路径, 无需 depmod)
modprobe cfg80211 2>/dev/null; modprobe mac80211 2>/dev/null
insmod "$M/uwe5621_bsp_sdio.ko" 2>/dev/null
sleep 3
insmod "$M/sprdwl_ng.ko" 2>/dev/null
insmod "$M/sprdbt_tty.ko" 2>/dev/null
sleep 2

# 蓝牙:CoreELEC 的 sprd hciattach 需要较新 glibc(Trixie 自带的太旧),
# 且 Debian 的 bluez hciattach 不含 sprd 协议(还会被 apt 升级覆盖)。
# 解法:CoreELEC 的 hciattach + 它自带的 glibc 一起放 /opt/ceglibc, 独立运行。
rfkill unblock bluetooth 2>/dev/null
CEG=/opt/ceglibc
if [ -e /dev/ttyBT0 ] && [ -x "$CEG/hciattach-sprd" ]; then
  "$CEG/ld-linux-aarch64.so.1" --library-path "$CEG" \
    "$CEG/hciattach-sprd" -s 1500000 /dev/ttyBT0 sprd &
fi
exit 0
