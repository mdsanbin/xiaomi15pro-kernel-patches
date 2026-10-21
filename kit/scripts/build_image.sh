#!/bin/bash
# Build an arm64 Image for Xiaomi 15 Pro (haotian) from a kernel tree
# that already contains the patches in ../patches.
#
# Usage: TC=/path/to/clang/bin OUT=/path/to/out ./build_image.sh
#        CCACHE=1 TC=/path/to/clang/bin OUT=/path/to/out ./build_image.sh
set -e
K=${K:-/path/to/kernel/tree}
OUT=${OUT:?set OUT to a fresh output directory}
TC=${TC:?set TC to a clang bin dir}
BASE=${BASE:-$(dirname "$0")/../config/haotian_6.6.144_aosp.config}
ARCH=arm64 LLVM=1 LLVM_IAS=1
export ARCH LLVM LLVM_IAS
export PATH="$TC:$PATH"

# scripts/setlocalversion appends "+"/"-dirty" when the working tree is not
# clean. Patched trees are never "clean", so build products would carry a
# trailing marker such as "6.6.144-Z-1.0.0+". Defining LOCALVERSION -- even as
# an empty string -- tells setlocalversion to skip that suffix. An explicit
# LOCALVERSION from the caller is preserved.
export LOCALVERSION="${LOCALVERSION-}"

# Optional ccache. Under LLVM=1 the kernel Makefile hardcodes "CC = clang",
# which overrides an environment CC, so ccache has to be injected as a make
# command-line variable instead. Enable with CCACHE=1 (or CCACHE=/path/to/ccache).
MAKE_CC=()
if [ -n "${CCACHE:-}" ] && [ "${CCACHE}" != "0" ]; then
	CCACHE_BIN=${CCACHE}
	[ "$CCACHE_BIN" = "1" ] && CCACHE_BIN=$(command -v ccache)
	[ -x "$CCACHE_BIN" ] && MAKE_CC=(CC="$CCACHE_BIN clang")
fi
if [ ${#MAKE_CC[@]} -eq 0 ]; then
	echo "ccache: disabled"
else
	echo "ccache: enabled (${MAKE_CC[0]})"
fi

mkdir -p "$OUT"
[ -f "$OUT/.config" ] || cp "$BASE" "$OUT/.config"
make -C "$K" O="$OUT" "${MAKE_CC[@]}" olddefconfig
make -C "$K" O="$OUT" "${MAKE_CC[@]}" -j"$(nproc)" Image
ls -la "$OUT/arch/arm64/boot/Image"
sha256sum "$OUT/arch/arm64/boot/Image"

# GKI symbol-CRC gate. The CRCs genksyms bakes into __kcrctab are the ABI that
# prebuilt vendor modules are linked against; if any of them drifts, those
# modules fail to load and the device hangs. The default baseline is derived
# from the device itself (see scripts/crc_from_modules.py): it contains only the
# symbols the shipped modules must get from the kernel, so it does not flag
# unrelated churn. Point CRC_BASELINE at another file to gate against a
# different set. Skip with CRC_GATE=0.
if [ "${CRC_GATE:-1}" != "0" ]; then
        python3 "$(dirname "$0")/crc_tool.py" gate \
                "$OUT/vmlinux" "${CRC_BASELINE:-$(dirname "$0")/../config/vendor_crc_baseline.txt}"
fi
