#!/bin/bash
# Build an arm64 Image for Xiaomi 15 Pro (haotian) from a kernel tree
# that already contains the patches in ../patches.
#
# Usage: TC=/path/to/clang/bin OUT=/path/to/out ./build_image.sh
set -e
K=${K:-/path/to/kernel/tree}
OUT=${OUT:?set OUT to a fresh output directory}
TC=${TC:?set TC to a clang bin dir}
BASE=${BASE:-$(dirname "$0")/../config/haotian_6.6.144_aosp.config}
ARCH=arm64 LLVM=1 LLVM_IAS=1
export ARCH LLVM LLVM_IAS
export PATH="$TC:$PATH"
mkdir -p "$OUT"
[ -f "$OUT/.config" ] || cp "$BASE" "$OUT/.config"
make -C "$K" O="$OUT" olddefconfig
make -C "$K" O="$OUT" -j"$(nproc)" Image
ls -la "$OUT/arch/arm64/boot/Image"
sha256sum "$OUT/arch/arm64/boot/Image"
