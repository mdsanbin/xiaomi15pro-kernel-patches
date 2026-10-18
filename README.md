# Xiaomi 15 Pro (haotian) kernel patches

Patches for a custom 6.6.142 GKI kernel for the Xiaomi 15 Pro (haotian),
plus the exact build configuration baseline and a build script.

## Root cause of the "stuck at the second screen" / libminikin corruption

Custom 6.6.142 builds hung at the second boot screen, and a locale test binary
reported `locale='' id=0x200d0000` where the stock kernel reports `0`
(537722880 vs 0).

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

Single-variable A/B: same source commit, same `.config` (final configs differ by
exactly the margin line), same toolchain, shim enabled in both.

| | margin base 32 (upstream) | margin base 65 (this patch, default) |
|---|---|---|
| empty-locale id | `0x200d0000` | **`0`** |
| boot | stuck at 2nd screen, adb reachable | **`sys.boot_completed=1`** |

Runtime evidence at margin 65 (dmesg):

    erofs: erofs lz4 decompress implace margin: 65      <- effective value at boot
    erofs-margin-dbg: in=4096 omargin=... margin=81 ...  <- 81 = 4096>>8 + 65
    erofs-lz4-dbg: in=... out=... ret=... maptype=3 bypass=1

`bypass=1` on every decode shows the vendor accelerated decoder is the one
actually decoding on this device.

Regression check: `sha256sum` of every file in `/system/lib64` (928 files) and
`/system/bin` (443 files) matches the stock baseline file-by-file (0 mismatches,
0 unexpected files).

## Limits (what is *not* proven here)

* The effective margin (65) is measured at runtime, but the `docopy` decision
  for the specific boundary pcluster was not captured directly by a print,
  because the diagnostic counter was exhausted earlier in the boot. It is
  derived from the measured margin (81) and the block geometry (omargin 50).
* The faulting decode itself (margin 32, in-place) was not instrumented, so its
  actual return value versus the destination capacity is not captured. The
  "3 bytes lost" statement comes from a byte-wise comparison of the decoded
  output; it is **not** a claim of an out-of-bounds write.

## Build

    TC=/path/to/clang/bin OUT=/path/to/fresh-out K=/path/to/kernel ./scripts/build_image.sh

The configuration baseline in `config/` is the exact `.config` used for the
verified build. LTO must stay disabled (`LTO_NONE`); do not enable ThinLTO.

## Packing / flashing

Not shipped here. The boot image was produced by wrapping the `Image` with
`mkbootimg` (header v4, kernel only) and re-attaching the **stock-signed**
vbmeta blob plus the AVB footer; the Xiaomi ABL still verifies that vbmeta
blob, so a self-signed one will not boot.
