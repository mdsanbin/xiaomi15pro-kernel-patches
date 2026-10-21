#!/bin/bash
# Verify that the tree/output match what this kit ships.
#
#   K=/path/tree OUT=/path/out ./verify.sh
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
K=${K:?set K}
OUT=${OUT:?set OUT}

echo "== applied sources are identical to the kit =="
( cd "$HERE/files" && find . -type f -print0 ) | while IFS= read -r -d '' f; do
	rel=${f#./}
	if cmp -s "$HERE/files/$rel" "$K/$rel"; then
		echo "  ok   $rel"
	else
		echo "  DIFF $rel"
		exit 1
	fi
done

echo "== zstd is 1.5.7 with the 6.6 adaptation =="
grep -q 'ZSTD_VERSION_RELEASE  7' "$K/include/linux/zstd_lib.h" && echo "  ok   zstd 1.5.7"
grep -q 'asm/unaligned.h' "$K/lib/zstd/common/mem.h" && echo "  ok   mem.h adapted"

echo "== effective .config =="
for s in CONFIG_CRYPTO_ZSTD CONFIG_CRYPTO_ZSTDN CONFIG_ZRAM CONFIG_ZSMALLOC \
         CONFIG_DEFAULT_TCP_CONG CONFIG_DEFAULT_NET_SCH CONFIG_LOCALVERSION; do
	v=$(grep -m1 "^$s=" "$OUT/.config" || true)
	[ -n "$v" ] && echo "  $v"
done

echo "== CRC gate =="
python3 "$HERE/scripts/crc_tool.py" gate "$OUT/vmlinux" "$HERE/config/vendor_crc_baseline.txt"

echo "== zstdn is registered in the built Image =="
IMG="$OUT/arch/arm64/boot/Image"
grep -aq 'zstdn-generic' "$IMG" && echo "  ok   zstdn-generic"
grep -aq 'zstdn-scomp' "$IMG" && echo "  ok   zstdn-scomp"
grep -aq 'Zstd Compression Algorithm (level 1)' "$IMG" && echo "  ok   zstdn description"

echo "== artifact hashes =="
sha256sum "$IMG"
[ -f "$HERE/out/boot.img" ] && sha256sum "$HERE/out/boot.img"
ls "$HERE/out"/*.zip >/dev/null 2>&1 && sha256sum "$HERE/out"/*.zip

echo
echo "verify: OK"
