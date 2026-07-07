# Corebian 工作原理

## 一、为什么不能用 mainline 内核

e900v22c 的 Unisoc UWE5621DS 挂在 Amlogic G12A 的 SDIO 控制器（`sd_emmc_a`）上。mainline 的 `meson-gx-mmc` 对 G12A SDIO 有个勘误 `dram_access_quirk`：控制器的 DMA 不能访问 DRAM，被迫走 1.5KB SRAM 反弹缓冲。结果 WiFi 扫描无响应、切 DDR 模式又在初始化卡死。

CoreELEC 用的是厂商 `meson-g12a-mmc` 驱动，DDR DMA 正常，UWE5621DS 的 WiFi + 蓝牙都能起来。所以我们要 CoreELEC 那颗 vendor 内核。

## 二、为什么必须走 bootm、不能用 booti

在盒子上跑 CoreELEC 时用 `fw_printenv` 读原厂 u-boot 环境变量：

```
booti 出现 0 次；bootm 出现 7 次
```

**这些盒子的原厂 Amlogic u-boot 根本没有 `booti` 命令**，只认 `bootm`（Android 镜像格式，`imgread kernel ...; bootm`）。任何用 booti 加载 raw `Image` 的方案，u-boot 不认识命令，内核从没被启动 —— 现象是**卡在 u-boot 自己画的开机 logo**，既不是黑屏也不是 recovery。

所以 Corebian 把 vendor 内核重打包成标准 Android `kernel.img`（`ANDROID!` 头，page 2048），保留**原始 lzop 压缩的内核字节**（bootm 会自动解 lzop），只把里面的 ramdisk 换成我们的迷你 initramfs。

## 三、启动完整链路

1. 盒子原厂 u-boot（preboot 阶段 `init_display` 画 logo、`storeargs` 备好 bootargs）
2. `bootcmd` → `bootfromusb` → 从 U 盘第一分区加载 `aml_autoscript`（**CoreELEC 版**，这是唯一能在这些盒子直接触发 U 盘启动的机制；ophub 的 autoscript 是「设 bootcmd 后重启」模式，在这些盒子上会掉进 recovery）
3. `aml_autoscript` → `cfgloadusb` → 加载并 `source` 我们的 `cfgload`
4. `cfgload`: `fatload kernel.img` + `fatload dtb.img` + `bootm`
5. bootm 解 lzop 内核 + 我们的迷你 initramfs 启动 vendor 内核（配 vendor dtb）
6. 迷你 initramfs `/init`：挂 `/dev/sda2` → `switch_root` 进 Armbian/Debian 的 systemd
7. systemd 起 `corebian-wifibt.service`：insmod 三个 vendor 模块 + `rfkill unblock` + `hciattach sprd`

## 四、蓝牙的 glibc 坑

CoreELEC 的 `hciattach`（带 sprd 协议）动态链接较新的 glibc（2.42/2.43）。Trixie 自带的 glibc 更旧，直接跑会报 `version GLIBC_2.42 not found`。而 Debian 的 bluez 包自带的 `hciattach` 又不含 sprd 协议（还会被 unattended-upgrades 覆盖回去）。

解法：把 CoreELEC 的 `hciattach` + 它自带的 `ld-linux-aarch64.so.1` + `libc.so.6` 一起丢进 `/opt/ceglibc/`，用

```
/opt/ceglibc/ld-linux-aarch64.so.1 --library-path /opt/ceglibc \
    /opt/ceglibc/hciattach-sprd -s 1500000 /dev/ttyBT0 sprd
```

独立运行，不动系统 glibc、也不怕 apt 升级覆盖。

## 五、为什么不需要 initramfs 加载存储驱动

vendor 内核把 `ext4` / `usb-storage` / `dwc3` / `dwc3-meson-g12a` / `xhci` / `meson-mmc` 全部**编进内核**（`modules.builtin` 里有、没有对应 `.ko`）。所以迷你 initramfs 只需 busybox 挂分区 + `switch_root`，不用加载任何模块。
