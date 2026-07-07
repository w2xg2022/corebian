#!/bin/bash
# build_corebian.sh —— Corebian 主构建脚本（注入式组装）
#
# 把「CoreELEC vendor 内核 blob」注入「Armbian/Debian rootfs」，产出可烧录镜像：
#   Corebian_<机型>_<用户空间>_<内核版本>_<日期>.img.gz
#
# 需要 root 运行（loop / mount / mkfs）。
#
# 用法:
#   sudo ./build_corebian.sh <board目录> <rootfs.tar.gz> <blob目录> [输出目录]
#
# blob 目录布局（out-of-tree 预编译固件，走 Releases 下发）:
#   kernel.img                 CoreELEC 原始 kernel.img（提供 lzop 内核）
#   modules-<KVER>.tar.gz      vendor 内核模块
#   firmware.tar.gz            vendor 固件（含 unisoc/*）
#   hciattach-sprd             CoreELEC 的 sprd hciattach
#   busybox                    aarch64 busybox（迷你 initramfs 用）
#   ceglibc/ld-linux-aarch64.so.1, ceglibc/libc.so.6   CoreELEC glibc
set -e
BOARD_DIR="$1"; ROOTFS_SRC="$2"; BLOB="$3"; OUT="${4:-$PWD/output}"
[ -d "$BOARD_DIR" ] && [ -f "$ROOTFS_SRC" ] && [ -d "$BLOB" ] || {
  echo "用法: sudo $0 <board目录> <rootfs.tar.gz> <blob目录> [输出目录]"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"      # 仓库根
. "$BOARD_DIR/board.conf"
DATE=$(date +%Y%m%d)
IMGNAME="Corebian_${MODEL}_${USERSPACE}_${KVER}_${DATE}"
mkdir -p "$OUT"
WORK=$(mktemp -d -p "$OUT")      # 工作目录放磁盘（避开可能是 tmpfs 的 /tmp）
ROOT="$WORK/root"; IRD="$WORK/initramfs"
mkdir -p "$ROOT" "$IRD"
echo "===== 构建 $IMGNAME ====="

echo "[1/6] 解压 rootfs"
tar xzf "$ROOTFS_SRC" -C "$ROOT"

echo "[2/6] 注入内核模块 + 固件"
mkdir -p "$ROOT/usr/lib/modules" "$ROOT/usr/lib/firmware"
tar xzf "$BLOB/modules-${KVER}.tar.gz" -C "$ROOT/usr/lib/modules/"
tar xzf "$BLOB/firmware.tar.gz"        -C "$ROOT/usr/lib/"

echo "[3/6] 注入 overlay + ceglibc(蓝牙 sprd hciattach)"
cp -a "$HERE/overlay/." "$ROOT/"
chmod +x "$ROOT/usr/local/sbin/corebian-wifibt-up.sh"
mkdir -p "$ROOT/opt/ceglibc"
cp "$BLOB/ceglibc/ld-linux-aarch64.so.1" "$BLOB/ceglibc/libc.so.6" "$ROOT/opt/ceglibc/"
cp "$BLOB/hciattach-sprd" "$ROOT/opt/ceglibc/hciattach-sprd"
chmod +x "$ROOT/opt/ceglibc/ld-linux-aarch64.so.1" "$ROOT/opt/ceglibc/hciattach-sprd"
# 启用服务
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf ../corebian-wifibt.service \
   "$ROOT/etc/systemd/system/multi-user.target.wants/corebian-wifibt.service"
# root 密码 1234 + 绕过 Armbian 首次登录
HASH=$(openssl passwd -6 1234)
HASH="$HASH" perl -i -pe 's{^root:[^:]*:}{"root:".$ENV{HASH}.":"}e' "$ROOT/etc/shadow"
rm -f "$ROOT/root/.not_logged_in_yet"
# 根设备（U 盘第二分区）
printf '/dev/sda2  /  ext4  defaults,noatime,errors=remount-ro  0 1\n' > "$ROOT/etc/fstab"

echo "[4/6] 组装迷你 initramfs + 重打包 bootm kernel.img"
mkdir -p "$IRD/usr/bin" "$IRD/lib" "$IRD/dev" "$IRD/proc" "$IRD/sys" "$IRD/mnt"
cp "$BLOB/busybox" "$IRD/usr/bin/busybox"; chmod +x "$IRD/usr/bin/busybox"
cp "$BLOB/ceglibc/ld-linux-aarch64.so.1" "$BLOB/ceglibc/libc.so.6" "$IRD/lib/"
cp "$HERE/initramfs/init" "$IRD/init"; chmod +x "$IRD/init"
bash "$HERE/build/make_kernelimg.sh" "$BLOB/kernel.img" "$IRD" "$WORK/kernel.img"
# 打包 eMMC 安装器 + 启动素材（供 corebian-install 用）+ 软链接 armbian-install
install -Dm755 "$HERE/install/corebian-install" "$ROOT/usr/sbin/corebian-install"
mkdir -p "$ROOT/usr/lib/corebian/boot"
cp "$WORK/kernel.img"        "$ROOT/usr/lib/corebian/boot/kernel.img"
cp "$BOARD_DIR/$DTB"         "$ROOT/usr/lib/corebian/boot/dtb.img"
cp "$BOARD_DIR/$CFGLOAD_TXT" "$ROOT/usr/lib/corebian/boot/cfgload.txt"
ln -sf corebian-install "$ROOT/usr/sbin/armbian-install"

echo "[5/6] 生成分区镜像"
mkimage -A arm -O linux -T script -C none -n cfgload \
        -d "$BOARD_DIR/$CFGLOAD_TXT" "$WORK/cfgload" >/dev/null
IMG="$OUT/$IMGNAME.img"
ROOTSZ=$(du -sm "$ROOT" | cut -f1); TOTAL=$((8 + 256 + ROOTSZ + 1200))
rm -f "$IMG"; truncate -s ${TOTAL}M "$IMG"
parted -s "$IMG" mklabel msdos
parted -s "$IMG" mkpart primary fat32 4MiB 260MiB
parted -s "$IMG" mkpart primary ext4 260MiB 100%
parted -s "$IMG" set 1 boot on
LOOP=$(losetup -fP --show "$IMG")
mkfs.vfat -n BOOT "${LOOP}p1" >/dev/null
mkfs.ext4 -q -L ROOTFS "${LOOP}p2"
MB="$WORK/mb"; MR="$WORK/mr"; mkdir -p "$MB" "$MR"
mount "${LOOP}p1" "$MB"
cp "$BOARD_DIR/$AML_AUTOSCRIPT" "$MB/aml_autoscript"
cp "$BOARD_DIR/$DTB"            "$MB/dtb.img"
cp "$WORK/cfgload"             "$MB/cfgload"
cp "$WORK/kernel.img"          "$MB/kernel.img"
sync; umount "$MB"
mount "${LOOP}p2" "$MR"; cp -a "$ROOT/." "$MR/"; sync; umount "$MR"
losetup -d "$LOOP"

echo "[6/6] 压缩"
gzip -f "$IMG"
rm -rf "$WORK"
echo "===== 完成: $OUT/$IMGNAME.img.gz ====="
ls -la "$OUT/$IMGNAME.img.gz"
