# Xiaomi 15 Pro (haotian) kernel patches

Patches for a custom GKI kernel for the Xiaomi 15 Pro (haotian). Verified on
both Xiaomi's `piano` 6.6.142 tree and a pure AOSP `android15-6.6.144_r00` tree,
together with build configuration baselines and a build script.

## Root cause of the "stuck at the second screen" / libminikin corruption

Custom builds hung at the second boot screen, and a locale test binary reported
`locale='' id=0x200d0000` where the stock kernel reports `0` (537722880 vs 0).
First seen on 6.6.142, later reproduced on a pure AOSP 6.6.144 tree.

The cause is the EROFS **LZ4 in-place decompression safety margin**:

* upstream uses `LZ4_DECOMPRESS_INPLACE_MARGIN(srcsize) = (srcsize >> 8) + 32`;
* for the boundary pcluster that holds libminikin.so's empty-locale id constant
  (`inputsize` 4096, `omargin` 50) that margin (48) is small enough to allow
  **in-place decoding**;
* the vendor accelerated LZ4 (`lz4asm`), which takes over decoding through the
  `android_vh_lz4_decompress_bypass` hook, then produces a corrupt output: the
  decoded content loses exactly 3 bytes starting at output offset 2048;
* that corrupts the cached id of the empty locale and the boot hangs.

Stock Xiaomi kernels raise the base from 32 to 65 and expose it through the
`z_erofs_get_lz4_decompress_inplace_margin` kernel boot parameter; boundary
pclusters then take the `docopy` path instead.

## Patches

| # | subject |
|---|---------|
| 0001 | `mm: add memfd ashmem compatibility shim` |
| 0002 | `erofs: make the LZ4 in-place decompression margin tunable (default 65)` |
| 0003 | `certs: keep key_pass declared without USE_PKCS11_ENGINE` |

Apply with `git am patches/*.patch`.

## Verification (Xiaomi 15 Pro, haotian)

Every row below is flash-tested on the device. Within a pair the only difference
is the margin base; the two trees are independent source trees (Xiaomi's
`piano` 6.6.142 tree and a pure AOSP `android15-6.6.144_r00` tree), and the
toolchain is AOSP clang r510928 in all of them.

| tree | LTO | margin base | empty-locale id | boot |
|---|---|---|---|---|
| piano 6.6.142 | none | 32 (upstream) | `0x200d0000` | stuck at 2nd screen, adb reachable |
| piano 6.6.142 | none | **65 (this patch)** | **`0`** | **`sys.boot_completed=1`** |
| pure AOSP 6.6.144 | none | 32 (upstream) | `0x200d0000` | stuck at 2nd screen, adb reachable |
| pure AOSP 6.6.144 | none | **65 (this patch)** | **`0`** | **`sys.boot_completed=1`** |
| pure AOSP 6.6.144 | thin | **65 (this patch)** | **`0`** | **`sys.boot_completed=1`**, 616 modules |

The same one-line change behaves identically on both trees, so the fix is not
tied to a vendor tree, and not to a specific optimisation setting either.

Runtime evidence at margin 65 (dmesg):

    erofs: erofs lz4 decompress implace margin: 65      <- effective value at boot
    erofs-margin-dbg: in=4096 omargin=... margin=81 ...  <- 81 = 4096>>8 + 65
    erofs-lz4-dbg: in=... out=... ret=... maptype=3 bypass=1

`bypass=1` on every decode shows the vendor accelerated decoder is the one
actually decoding on this device.

Regression check: `sha256sum` of every file in `/system/lib64` (928 files) and
`/system/bin` (443 files) matches the stock baseline file-by-file (0 mismatches,
0 unexpected files).

Vendor modules load normally: `/proc/modules` lists 616 modules, matching the
stock baseline entry for entry, and dmesg contains no
`disagrees about version of symbol`, `Unknown symbol` or
`module verification failed` lines.

## Limits (what is *not* proven here)

* The effective margin (65) is measured at runtime, but the `docopy` decision
  for the specific boundary pcluster was not captured directly by a print,
  because the diagnostic counter was exhausted earlier in the boot. It is
  derived from the measured margin (81) and the block geometry (omargin 50).
* The faulting decode itself (margin 32, in-place) was not instrumented, so its
  actual return value versus the destination capacity is not captured. The
  "3 bytes lost" statement comes from a byte-wise comparison of the decoded
  output; it is **not** a claim of an out-of-bounds write.
* The crash signature is not identical across trees: the pure-AOSP runs crashed
  in `FontFamily::FontFamily()` / `FontFamily::create()` in `libminikin.so`,
  while the earlier piano-tree runs crashed on the `LocaleListCache` /
  `getIdInternal` path. Both arms do show the same corrupted empty-locale id
  (`0x200d0000`); whether that is one causal chain or one corrupt value consumed
  at two different sites is not settled here.

## Build

    TC=/path/to/clang/bin OUT=/path/to/fresh-out K=/path/to/kernel ./scripts/build_image.sh

Two baselines are provided, each the exact `.config` of a build that was
flash-tested on the device:

| config | tree | LTO |
|---|---|---|
| `config/haotian_6.6.144_aosp.config` (**default**, used by the script) | pure AOSP `android15-6.6.144_r00` | `LTO_CLANG_THIN` |
| `config/haotian_6.6.142_piano.config` | Xiaomi `piano` 6.6.142 | `LTO_NONE` |

They are baselines rather than portable configs: for another tree or version,
run `make olddefconfig` and expect Kconfig-driven differences (the 6.6.142 and
6.6.144 trees differ in about 221 lines, mostly vendor platform symbols).

The margin base does **not** come from the config — it is patch 0002, a source
change — so a build needs the patches applied; alternatively pass
`z_erofs_get_lz4_decompress_inplace_margin=65` on the kernel command line.

The verified builds used the AOSP clang r510928 (18.0.0) toolchain. The
tool-version lines at the top of a `.config` (`CONFIG_CC_VERSION_TEXT`,
`CONFIG_CLANG_VERSION`, `CONFIG_AS_VERSION`, `CONFIG_LLD_VERSION`) are
auto-detected and are rewritten by `olddefconfig`, so building with a different
clang silently restamps them.

LTO is not a hard requirement: the exported-symbol CRC tables are byte-for-byte
identical under `LTO_NONE` and `LTO_CLANG_THIN` (`__kcrctab` 24532 B and
`__kcrctab_gpl` 42320 B), which is expected since `genksyms` derives the CRCs
from preprocessed sources, and the ThinLTO build boots with the same 616 modules
and no symbol-version errors. To switch modes, flip two lines: `CONFIG_LTO_NONE=y`
off, and `CONFIG_LTO_CLANG_THIN=y` on (`CONFIG_LTO` / `CONFIG_LTO_CLANG` are
hidden symbols that `olddefconfig` fills in).

## Packing / flashing

Not shipped here. The boot image was produced by wrapping the `Image` with
`mkbootimg` (header v4, kernel only) and re-attaching the **stock-signed**
vbmeta blob plus the AVB footer; the Xiaomi ABL still verifies that vbmeta
blob, so a self-signed one will not boot.
