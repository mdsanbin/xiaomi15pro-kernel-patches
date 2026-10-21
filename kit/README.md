# Mi15 Pro (haotian) 自定义内核复刻包 v1

目标：在任意一台 Linux/WSL 机器上，从**纯 AOSP android15-6.6.144_r00 内核树**复刻出与本项目
已验证产物一致的内核（Image / boot 镜像 / AnyKernel3 包），并保留全部关键约束与踩坑记录。

本包里所有源码文件都是**已验证的全量文件**（不是补丁），所以复刻不依赖补丁上下文能否对上。

---

## 0. 目录结构

```
apply.sh                    把 files/ + zstd 1.5.7 应用到内核树
build_all.sh                编译 → CRC 门禁 → 打包 boot.img + AK3（含调优模块）
verify.sh                   逐项校验（源码一致性 / 门禁 / zstdn 注册 / 哈希）
files/                      已验证的源码文件（按内核树相对路径存放，全量覆盖）
  arch/arm64/lib/clear_page.S              __pi_clear_page 前加 .p2align 4
  fs/f2fs/f2fs.h                           DEFAULT_IO_TIMEOUT 20ms → 6ms
  fs/erofs/decompressor.c                  LZ4 in-place 余量可调（默认 65）
  include/linux/compiler_types.h           __GENKSYMS__ 下屏蔽 __counted_by（CRC 修复）
  crypto/Kconfig / crypto/Makefile         CRYPTO_ZSTDN 接入
  crypto/zstdn.c                           新增：zstd level 1 的 crypto 后端
vendor/zstd157.tar.gz        lib/zstd 1.5.7 + include/linux/zstd*.h（已含 6.6 适配）
vendor/AK3/                  AnyKernel3 模板（osm0sis，GPL）
tools/mkbootimg.py           boot image 头 v4 打包
tools/repack-stock-avb.py    复用 stock 签名 vbmeta + AVB footer
scripts/build_image.sh       编译脚本（内含 CRC 门禁）
scripts/pack_boot.sh         Image → boot.img + AK3
scripts/crc_tool.py          符号 CRC 门禁
scripts/crc_from_modules.py  从设备模块的 __versions 生成基线
config/                      已验证的 .config、厂商 CRC 基线与 importer 索引
patches/                     历史上的补丁（0001-0004，供审阅，apply.sh 不依赖它）
module/                      运行时调优模块（KSU/Magisk，zram → zstdn）
```

---

## 1. 前置条件

| 项 | 要求 |
|---|---|
| 内核树 | AOSP `android15-6.6.144_r00`，纯净未改 |
| 工具链 | LLVM **22.1.8**（`clang`/`ld.lld`/`llvm-ar`/`llvm-nm`） |
| 系统工具 | `python3`、`zip`、`tar`、`git` |
| 磁盘 | ≥ 40 GB（ThinLTO 输出约 5 GB，另需源树与包） |
| 内存 | ≥ 16 GB 建议 |
| **stock boot.img** | 本机原厂 boot 镜像，**必需**——只用来取 stock 签名的 vbmeta blob。小米 ABL 解锁后仍校验它，自签 vbmeta 会直接进 fastboot |

> 若使用 apt 版 LLVM 22，运行时可能需要
> `export LD_LIBRARY_PATH=/usr/lib/llvm-22/lib`（或对应的 libLLVM.so.22.1 所在目录）。

---

## 2. 三步复刻

```bash
export K=/path/to/aosp_gki_6.6.144
export OUT=/path/to/out
export TC=/path/to/llvm-22/bin
export STOCK_BOOT=/path/to/stock_boot.img      # 打包阶段必需

./apply.sh          # 应用源码（全量覆盖 + 解压 zstd 1.5.7）
./build_all.sh      # 编译 → 门禁 → 打包 → 自校验
./verify.sh         # 独立复核
```

只想要 Image、不打包：不设 `STOCK_BOOT` 即可，`build_all.sh` 会在产完 Image 后停下。

产物在 `OUT/arch/arm64/boot/Image` 与 `./out/{boot.img,*.zip}`。

**重要**：构建一旦失败或被中断，必须 `RESET_OUT=1 ./build_all.sh`（等价于 `rm -rf OUT`）。
在脏输出目录上做增量构建会出现 `llvm-ar: xxx.o: No such file` / `fixdep: .xxx.o.d` 这类假错误。

---

## 3. 已验证的参考结果（LLVM 22.1.8 + ThinLTO）

| 产物 | 大小 | sha256 |
|---|---|---|
| Image | 37,915,136 B | `85fd8766a9628715b369b8272ed910d517f5baca5e83bd74e060c31b6e6d5bd3` |
| boot_z3.img | 100,663,296 B | `57b0a811ffc13cdd770ade2cb3988c6a9a9d8e419372f59e0492fe1d326401cb` |
| AK3（含模块） | 18,285,115 B | `9a9f8214310afc79f432026ad9c179001923c9be7e0baf578d6a6a7a07acc689` |

哈希对编译器版本、LTO 模式、目录路径敏感，**不要把它当唯一判据**。真正的判据是：

1. `CRC_GATE: PASS`，`DIFFERENT_CRC=0`，`only_in_baseline=0`
2. Image 里存在 `zstdn-generic` / `zstdn-scomp` / `Zstd Compression Algorithm (level 1)`
3. boot.img 内嵌 kernel 的 sha256 与 Image 一致，且 AVB blob 以 `AVB0` 开头、整包恰为 96 MiB

---

## 4. 关键约束（都是实机踩出来的，务必遵守）

1. **不要把 `zram` / `zsmalloc` 改成 `=y`。**
   `vendor_boot` ramdisk 的 `/lib/modules/modules.load` 依次加载
   `zsmalloc.ko`(第 12 行)、`zram.ko`(第 84 行)、`node_cache.ko`(第 134 行)。
   一旦内建，这两条 insmod 必失败（EEXIST；ramdisk 的 zram.ko 还依赖小米私有符号
   `zs_malloc_mi`），一级模块加载链会在第 84 行截断，后续 64 个模块不加载 → **卡第一屏、adb 不起**。
2. **CRC 门禁用厂商模块基线，不用全量导出基线。**
   基线来自设备上 643 个模块的 `__versions`：6438 个被需求符号，其中 5398 个由模块互相提供，
   **3967 个必须由 vmlinux 提供**。换编译器/换 LTO 不会让这条基线失效。
3. **lib/zstd 1.5.7 只有一处 6.6 适配**：`lib/zstd/common/mem.h` 的
   `#include <linux/unaligned.h>` → `<asm/unaligned.h>`（`linux/unaligned.h` 是 6.12 才拆出的头）。
   6.15 的头文件仍声明 `zstd_init_cstream` / `zstd_compress_stream` / `zstd_end_stream` /
   `zstd_init_dstream` / `zstd_decompress_stream`，因此 btrfs / f2fs / squashfs / incfs /
   module 解压等消费方**无需改动**。
4. **`zstdn` 复用同一份 `lib/zstd`**，只是换默认级别（1），注册成新的 crypto 名字。
   不要复制整库，也不要使用 `--allow-multiple-definition`（ThinLTO 下会出问题）。
5. **AK3 只能通过 KernelSU / Magisk 刷。** `fastboot flash boot_a boot.img` 只会换内核，
   不会安装 `tune_module`；那种情况请单独安装 `Mi15_Tune_v1.1.zip`。
6. **zram0 运行中不能换算法**：`comp_algorithm` 要求 `disksize=0`。
   模块在 `post-fs-data` 走 `swapoff → reset → 设算法 → 设 disksize → mkswap → swapon`，
   并且在 `zstdn` 不存在于 `/proc/crypto` 时**完全不动**（在旧内核上装模块是安全的空操作）。
7. **Scene 会重建 zram**（`scene-daemon`）。若其配置的算法不是 `zstdn`，会把模块设的值覆盖回去；
   需要在 Scene 里选 `zstdn`，或关闭它的 zram 接管。`module/tune.log` 的 `boot-completed` 记录可判断最终值。

---

## 5. 刷机与回滚

```bash
# 内核（会同时安装调优模块，需 KSU/Magisk 里刷 zip）
# 或仅内核：
fastboot flash boot_a boot.img
fastboot reboot
```

- 活动槽：`fastboot getvar current-slot`。**刷之前先确认槽位并保留对应备份**。
- `boot_z1.img`（上一版，无 zstdn）可用于回滚；原厂 `boot_stock.img` 亦可。
- 刷完的验证：`sys.boot_completed=1`、`/proc/version` 含 `-Z-1.0.0`、
  dmesg 无 `disagrees about version` / `Unknown symbol`、`/proc/crypto` 有 `zstdn`、
  `cat /sys/block/zram0/comp_algorithm` 显示 `[zstdn]`。

---

## 6. 重新生成 CRC 基线（厂商 OTA 后）

模块集合来自三处，缺一不可：

- `/vendor_dlkm/lib/modules`（`/vendor/lib/modules` 是其软链）
- `/system_dlkm/lib/modules`（`/system/lib/modules` 同为软链）
- **`vendor_boot` ramdisk 的 `/lib/modules`**（一级模块，不在任何已挂载文件系统上，
  需要 `dd` 出 `vendor_boot_a` 分区再按 v4 头 + legacy LZ4 + cpio 解包）

然后：

```bash
python3 scripts/crc_from_modules.py <模块根目录> config/vendor_crc_baseline.txt \
        --loaded lsmod.txt --vmlinux "$OUT/vmlinux"
```

会同时写出 `vendor_crc_baseline.importers.txt`（符号 → 索要它的模块），
门禁失败时可直接点名“哪些 .ko 会拒载”。

---

## 7. 许可与来源

- `vendor/AK3/`：AnyKernel3，osm0sis，GPL-2.0
- `tools/mkbootimg.py`、`tools/repack-stock-avb.py`：来自 Mi15-Droidspaces-Kernel（开源）
- `lib/zstd`：Meta/Facebook Zstandard 1.5.7，GPL-2.0+ OR BSD-3-Clause
- 其余为本项目自有改动
