#!/bin/bash
# Apply the verified source state of this kit onto a clean AOSP 6.6.144 tree.
#
# Usage:  K=/path/to/aosp_gki_6.6.144 ./apply.sh
set -e

K=${K:?set K to the kernel tree (android15-6.6.144_r00)}
HERE=$(cd "$(dirname "$0")" && pwd)

echo "[1/3] copying verified source files"
( cd "$HERE/files" && find . -type f -print0 ) | while IFS= read -r -d '' f; do
	rel=${f#./}
	mkdir -p "$K/$(dirname "$rel")"
	cp -f "$HERE/files/$rel" "$K/$rel"
	echo "  $rel"
done

echo "[2/3] installing lib/zstd 1.5.7 (vendored kernel port)"
tar -xzf "$HERE/vendor/zstd157.tar.gz" -C "$K"
echo "  lib/zstd + include/linux/zstd*.h"

echo "[3/3] sanity checks"
fail() { echo "apply: FAILED - $*"; exit 1; }
grep -q '^config CRYPTO_ZSTDN' "$K/crypto/Kconfig" || fail "crypto/Kconfig has no CRYPTO_ZSTDN"
grep -q 'zstdn.o' "$K/crypto/Makefile" || fail "crypto/Makefile does not build zstdn.o"
grep -q 'ZSTD_VERSION_RELEASE  7' "$K/include/linux/zstd_lib.h" || fail "lib/zstd is not 1.5.7"
grep -q 'asm/unaligned.h' "$K/lib/zstd/common/mem.h" || fail "mem.h was not adapted for 6.6"
grep -q 'ZSTDN_DEF_LEVEL' "$K/crypto/zstdn.c" || fail "crypto/zstdn.c missing"

echo
echo "apply: OK"
echo "  next: K=\$K OUT=/path/out TC=/path/llvm22/bin ./build_all.sh"
