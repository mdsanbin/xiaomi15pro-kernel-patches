#!/bin/bash
# Build the kernel Image, run the vendor-module CRC gate, then pack boot.img + AK3.
#
# Usage:
#   K=/path/to/aosp_gki_6.6.144 OUT=/path/out TC=/path/llvm22/bin ./build_all.sh
#
# Optional:
#   STOCK_BOOT=/path/stock_boot.img   enable packing (required for packing)
#   MODULE_DIR=/path/module           bundle the runtime tune module (default: ./module)
#   KERNEL_STRING="..."               AK3 display string
#   RESET_OUT=1                       wipe OUT first (REQUIRED after a failed build)
#   CRC_BASELINE=/path/baseline.txt   override the CRC baseline
#   CRC_GATE=0                        skip the gate (not recommended)
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
K=${K:?set K to the kernel tree}
OUT=${OUT:?set OUT to an output dir}
TC=${TC:?set TC to a clang bin dir}

if [ "${RESET_OUT:-0}" = "1" ]; then
	echo "== RESET_OUT: removing $OUT =="
	rm -rf "$OUT"
fi

echo "== build =="
K="$K" OUT="$OUT" TC="$TC" bash "$HERE/scripts/build_image.sh"
IMG="$OUT/arch/arm64/boot/Image"

if [ -z "${STOCK_BOOT:-}" ]; then
	echo
	echo "STOCK_BOOT not set, skipping packing."
	echo "Image: $IMG"
	exit 0
fi

echo
echo "== pack =="
IMG="$IMG" STOCK_BOOT="$STOCK_BOOT" OUTDIR="${OUTDIR:-$HERE/out}" \
	MODULE_DIR="${MODULE_DIR:-$HERE/module}" \
	KERNEL_STRING="${KERNEL_STRING:-Xiaomi 15 Pro Kernel 6.6.144-Z-1.0.0}" \
	bash "$HERE/scripts/pack_boot.sh"

echo
echo "== verify =="
K="$K" OUT="$OUT" bash "$HERE/verify.sh"
