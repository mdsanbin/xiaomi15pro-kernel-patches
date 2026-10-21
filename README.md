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
| 0004 | `genksyms: keep capability-gated __counted_by out of the GKI symbol CRCs` |

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

## Exported-symbol CRCs (GKI ABI invariant)

The GKI ABI is fixed by the Android reference build: every exported symbol's
`__crc_*` value must match it exactly, or prebuilt vendor modules refuse to load
(`disagrees about version of symbol ...` / `Unknown symbol ...`).

On clang >= 19.1.3 the Kconfig gate `CONFIG_CC_HAS_COUNTED_BY` turns `__counted_by`
from an empty macro into `__attribute__((__counted_by__(member)))`. Because
`struct icc_path { ... struct icc_req reqs[] __counted_by(num_nodes); }` uses it,
`genksyms` folded the attribute into the type and drifted **14 of 16713** CRCs
(`icc_set_bw` `0x54401b7c` -> `0x912111d7`). `qcom-scm.ko` then failed to load
and Q6/ADSP never came up, which hangs the boot (dead at ~10.7 s).

Patch 0004 expands such capability-gated type attributes to nothing under
`__GENKSYMS__`, while the real compiler still receives them, so the CRCs stay at
the reference values and the hardening is kept. The CRCs are independent of the
compiler version and of the LTO mode, so one baseline covers clang 18/20/21/22
and both `LTO_NONE` and `LTO_CLANG_THIN`.

`config/gki_crc_baseline.txt` is that reference set (16713 symbols) and
`scripts/crc_tool.py` checks a build against it:

    python3 scripts/crc_tool.py gate <out>/vmlinux config/gki_crc_baseline.txt

`scripts/build_image.sh` runs this automatically after `make Image` and fails on
any drift. Set `CRC_GATE=0` to skip it.

### Device-derived baseline (default)

A full-tree reference says what *our* build exports; it does not say what the
prebuilt modules actually ask for. The latter is the real constraint, and it
can be read off the device:

    scripts/crc_from_modules.py <module-dir> config/vendor_crc_baseline.txt \
        [--loaded lsmod.txt] [--vmlinux <out>/vmlinux]

Each `.ko` built with `CONFIG_MODVERSIONS` carries a `__versions` section
(`struct modversion_info { unsigned long crc; char name[56]; }`, 64 B/entry):
the CRCs it demands from the kernel at load time. The script unions those
across every shipped module, subtracts the symbols that modules export to each
other (these are satisfied inside the module set and are not kernel ABI), and
keeps the rest as the must-match set.

Getting the module set right matters. On this device it comes from three
places, and the third is easy to miss:

| source | `.ko` files |
|---|---|
| `/vendor_dlkm/lib/modules` (also reachable as `/vendor/lib/modules`) | 399 |
| `/system_dlkm/lib/modules` (also reachable as `/system/lib/modules`) | 96 |
| **`vendor_boot` ramdisk `/lib/modules`** -- first-stage modules, not on any mounted filesystem | 441 |

The three sets overlap (many modules ship both in the ramdisk and in
`vendor_dlkm`), so counts for `haotian` (OS 4.0.0.19) come out as:

    modules_found   = 1032 files   (includes a flattened duplicate of /system_dlkm)
    unique contents = 643          (389 byte-identical duplicates dropped)
    required_symbols= 6438         demanded by some shipped module
    module_provided = 5398         satisfied by another shipped module
    kernel_required = 3967         must come from vmlinux

Against the 6.6.144-Z-1.0.0 build: `missing_in_vmlinux = 0`,
`DIFFERENT_CRC = 0`. The set is also small enough to stay quiet: symbol churn
elsewhere in the tree can no longer trip the gate, while every CRC a module
really checks is still enforced -- `icc_set_bw`, for instance, is in it, so the
clang >= 19 `__counted_by` drift described above fails the build.

`scripts/build_image.sh` uses this baseline by default; override with
`CRC_BASELINE=<file>`. To regenerate it, re-pull the three directories from the
device (read-only) and re-run the script. Because the baseline only encodes
what the modules demand, it stays valid across compiler versions and LTO modes,
and only needs refreshing after a vendor/OTA module update.
