# Corebian

**Corebian = CoreELEC + Armbian** —— 一套「缝合」固件方案。

把 **CoreELEC 的 vendor 内核**（闭源 Amlogic BSP，能驱动 mainline 驱动不了的硬件，例如 UWE5621DS WiFi/蓝牙）和 **Armbian 的干净 userland**（基于 Debian，systemd + apt）缝合到一起，用 `bootm` + `switch_root` 启动。

> 适合那些「硬件只有原厂 BSP 内核能驱动，但又想要现代 Debian 用户空间」的 Amlogic 电视盒。

## 为什么需要它

以 e900v22c（Amlogic S905L3A / G12A）为例，板载 Unisoc UWE5621DS（MARLIN3E）SDIO WiFi+蓝牙二合一：

- **mainline 内核**：`meson-gx-mmc` 的 SDIO DMA 有 G12A 勘误（`dram_access_quirk`），扫描无响应 / 初始化卡死 —— WiFi 起不来。
- **CoreELEC 5.15 vendor 内核**：用厂商 `meson-g12a-mmc`，DDR DMA 正常，WiFi + 蓝牙都能用。
- 但 CoreELEC 是 busybox + Kodi，不是通用 Debian。

**Corebian 的做法**：拿 CoreELEC 那颗能驱动硬件的 5.15 vendor 内核 + 模块 + 固件，缝到 Armbian Trixie 的 rootfs 上。

## 启动链（关键：这些盒子的原厂 u-boot 只有 `bootm`，没有 `booti`）

```
盒子原厂 u-boot（只认 bootm，Android 镜像格式）
  └─ CoreELEC aml_autoscript（唯一能在这些盒子触发 U 盘启动的机制）
      └─ cfgload → bootm 重打包的 Android kernel.img
          ├─ CoreELEC vendor 内核（原始 lzop 压缩）
          └─ 迷你 initramfs → 挂 rootfs 分区 → switch_root
              └─ Armbian rootfs（Debian 系）+ systemd
                  ├─ vendor 内核模块（WiFi/蓝牙驱动，out-of-tree 注入）
                  ├─ vendor 固件（wcnmodem.bin / bt pskey）
                  └─ /opt/ceglibc（自带 glibc 的 sprd hciattach，蓝牙用）
```

> **踩过的最大坑**：这些盒子的原厂 u-boot **没有 `booti` 命令**，只有 `bootm`。任何用 booti 的方案（raw Image）都会卡在开机 logo。必须把内核重打包成 Android `kernel.img` 走 `bootm`。

## 命名规范

```
Corebian_<机型>_<用户空间>_<内核版本>_<编译日期YYYYMMDD>.img.gz
例：Corebian_E900V22C_Trixie_5.15.196_20260707.img.gz
```

## 目录结构

| 路径 | 说明 |
|------|------|
| `build/build_corebian.sh` | 主构建脚本：注入式组装，产出规范命名镜像 |
| `build/make_kernelimg.sh` | 重打包 Android `kernel.img`（lzop 内核 + 迷你 initramfs） |
| `initramfs/init` | switch_root 迷你 init |
| `boards/<model>/` | 板级：`board.conf`、`aml_autoscript`、`dtb.img`、`cfgload.txt` |
| `overlay/` | 注入 rootfs 的文件（wifibt 服务、模块自加载、脚本） |
| `docs/` | 原理文档 |

**大二进制**（内核 Image、内核模块、固件、glibc、sprd hciattach）作为 **GitHub Releases** 的注入素材下发，不进 git。最终镜像也放 Releases。

## 已支持机型

| 机型 | SoC | 无线芯片 | 内核 | 用户空间 | 状态 |
|------|-----|----------|------|----------|------|
| E900V22C | S905L3A / G12A | UWE5621DS | 5.15.196 | Armbian (Trixie) | ✅ WiFi + 蓝牙 |

## 默认账号

`root` / `1234`（首次登录后请自行修改）

## 致谢

- [CoreELEC](https://coreelec.org/) —— vendor 内核与驱动
- [ophub/amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian) —— Armbian rootfs 与启动链参考
- UWE5621DS 驱动社区

## 许可

构建脚本以 MIT 授权；注入的内核/模块/固件/rootfs 各自保留其原始许可（CoreELEC/Armbian 多为 GPL）。
