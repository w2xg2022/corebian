#!/bin/bash
# make_kernelimg.sh —— 把 CoreELEC 原始 kernel.img 重打包成
# 「原始 lzop 内核 + Corebian 迷你 switch_root initramfs」的 Android bootimg，走 bootm 启动。
#
# 用法: make_kernelimg.sh <原始kernel.img> <initramfs根目录> <输出kernel.img>
set -e
SRC_IMG="$1"; IRD_DIR="$2"; OUT_IMG="$3"
[ -f "$SRC_IMG" ] && [ -d "$IRD_DIR" ] && [ -n "$OUT_IMG" ] || {
  echo "用法: $0 <原始kernel.img> <initramfs目录> <输出kernel.img>"; exit 1; }

WORK=$(mktemp -d -p "$(dirname "$OUT_IMG")")   # 与输出同盘，避开可能是 tmpfs 的 /tmp
echo "[*] 打包 initramfs (cpio+gzip, root 拥有)"
( cd "$IRD_DIR" && find . | cpio -o -H newc -R 0:0 2>/dev/null | gzip -9 ) > "$WORK/ramdisk.gz"

echo "[*] 重打包 Android bootimg (保留原 header/地址, 换内核ramdisk)"
python3 - "$SRC_IMG" "$WORK/ramdisk.gz" "$OUT_IMG" <<'PYEOF'
import struct, sys
src, rd, out = sys.argv[1], sys.argv[2], sys.argv[3]
d = open(src,'rb').read()
magic,ksz,kaddr,rsz,raddr,ssz,saddr,tags,ps = struct.unpack('<8sIIIIIIII', d[:40])
assert magic == b'ANDROID!', '不是 Android bootimg'
rest   = d[40:ps]                 # 保留 header 其余(version/name/cmdline/id/extra)
kernel = d[ps:ps+ksz]             # 原始内核字节(通常 lzop, bootm 会解压)
ramdisk= open(rd,'rb').read()
hdr = struct.pack('<8sIIIIIIII', magic, len(kernel), kaddr, len(ramdisk), raddr, ssz, saddr, tags, ps) + rest
pad = lambda b: b + b'\x00'*((ps-len(b)%ps)%ps)
open(out,'wb').write(pad(hdr)+pad(kernel)+pad(ramdisk))
print('    kernel=%d  ramdisk=%d  page=%d  -> %s' % (len(kernel),len(ramdisk),ps,out))
PYEOF
rm -rf "$WORK"
echo "[✓] 完成: $OUT_IMG"
