#!/bin/bash
# Pack an Image into a stock-signed boot image and an AnyKernel3 zip.
#
#   IMG=/path/Image STOCK_BOOT=/path/stock_boot.img ./pack_boot.sh
#
# The stock boot image is only used as the source of the stock-signed vbmeta
# blob and the AVB footer layout: Xiaomi's ABL still verifies that blob, so a
# self-signed vbmeta sends the device straight to fastboot.
set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
IMG=${IMG:?set IMG to arch/arm64/boot/Image}
STOCK=${STOCK_BOOT:?set STOCK_BOOT to the stock boot.img of the device}
OUTDIR=${OUTDIR:-$HERE/out}
MODDIR=${MODULE_DIR:-}
BOOTNAME=${BOOTNAME:-boot.img}
ZIPNAME=${ZIPNAME:-Mi15Pro_Kernel_AK3.zip}
KSTRING=${KERNEL_STRING:-Xiaomi 15 Pro Kernel}
PART=${PART_SIZE:-100663296}

mkdir -p "$OUTDIR"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

echo "== mkbootimg (header v4, kernel only) =="
python3 "$HERE/tools/mkbootimg.py" --header_version 4 --kernel "$IMG" --out "$W/boot.raw.img"

echo "== repack stock vbmeta blob + AVB footer =="
python3 "$HERE/tools/repack-stock-avb.py" "$W/boot.raw.img" "$STOCK" "$OUTDIR/$BOOTNAME"

echo "== self-verify =="
python3 - "$OUTDIR/$BOOTNAME" "$IMG" "$PART" <<'PY'
import sys, struct, hashlib
bo = open(sys.argv[1],'rb').read(); im = open(sys.argv[2],'rb').read()
part = int(sys.argv[3])
assert bo[:8] == b'ANDROID!', "bad magic"
ks = struct.unpack_from('<I', bo, 8)[0]
hv = struct.unpack_from('<I', bo, 40)[0]
assert ks == len(im), "kernel size mismatch"
k = bo[4096:4096+ks]
assert hashlib.sha256(k).digest() == hashlib.sha256(im).digest(), "embedded kernel differs"
blob = (4096+ks+4095)//4096*4096
assert bo[blob:blob+4] == b'AVB0', "AVB blob missing"
assert len(bo) == part, "image is not %d bytes" % part
print("  header_version=%d kernel=%d bytes, AVB@%d, total=%d -> OK" % (hv, ks, blob, len(bo)))
PY

echo "== AnyKernel3 zip =="
mkdir -p "$W/ak3"
cp -a "$HERE/vendor/AK3/." "$W/ak3/"
rm -rf "$W/ak3/.git" "$W/ak3/.github"
cp "$IMG" "$W/ak3/Image"

HAVE_MOD=0
if [ -n "$MODDIR" ] && [ -d "$MODDIR" ]; then
	HAVE_MOD=1
	mkdir -p "$W/ak3/tune_module"
	cp -a "$MODDIR/." "$W/ak3/tune_module/"
	sed -i 's/\r$//' "$W/ak3/tune_module/module.prop" "$W/ak3/tune_module"/*.sh 2>/dev/null || true
	chmod 755 "$W/ak3/tune_module"/*.sh 2>/dev/null || true
	chmod 644 "$W/ak3/tune_module/module.prop" 2>/dev/null || true
fi

cat > "$W/ak3/anykernel.sh" <<AK
### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

properties() { '
kernel.string=${KSTRING}
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=haotian
device.name2=dada
device.name3=xuanyuan
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; }

BLOCK=boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;
NO_MAGISK_CHECK=1;

. tools/ak3-core.sh;

split_boot;
flash_boot;
AK

if [ "$HAVE_MOD" = "1" ]; then
cat >> "$W/ak3/anykernel.sh" <<'AK'

# --- bundled runtime tune module (KernelSU / Magisk) ---
if [ -d "$AKHOME/tune_module" ]; then
  if [ -d /data/adb/modules ]; then
    ui_print " ";
    ui_print "- Installing runtime tune module";
    rm -rf /data/adb/modules/mi15_kernel_tune;
    cp -af "$AKHOME/tune_module" /data/adb/modules/mi15_kernel_tune;
    chmod 755 /data/adb/modules/mi15_kernel_tune/*.sh;
    chmod 644 /data/adb/modules/mi15_kernel_tune/module.prop;
    touch /data/adb/modules/mi15_kernel_tune/update;
    ui_print "- Module installed; it takes effect on the next boot";
  else
    ui_print " ";
    ui_print "- /data/adb/modules not found, tune module not installed";
  fi
fi
AK
fi

( cd "$W/ak3" && find . -mindepth 1 -not -path './.git*' -not -path './.github*' | zip -9 "$OUTDIR/$ZIPNAME" -@ >/dev/null )

echo "== result =="
sha256sum "$IMG" "$OUTDIR/$BOOTNAME" "$OUTDIR/$ZIPNAME"
