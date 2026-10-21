#!/system/bin/sh
# Mi15 tune - zram default compression = zstdn
#
# zram0 is initialised and mounted as swap by fs_mgr during first stage, i.e.
# long before any KernelSU module script runs.  The compression algorithm can
# only be changed while disksize == 0, so the device has to be fully reset:
#
#   swapoff -> reset -> comp_algorithm=zstdn -> disksize -> mkswap -> swapon
#
# Everything is validated first and rolled back on failure.  If the running
# kernel has no zstdn (i.e. not the Z3 build), the script does nothing.

MODDIR=${0%/*}
LOG=$MODDIR/tune.log
ALGO=zstdn
DEV=/dev/block/zram0
SYS=/sys/block/zram0

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [zram] $*" >> "$LOG"; }

# Only act when the algorithm is really registered in crypto.
if ! grep -qE "^name[[:space:]]*: ${ALGO}\$" /proc/crypto 2>/dev/null; then
	log "$ALGO not registered in this kernel, leaving zram alone"
	exit 0
fi

[ -b "$DEV" ] || { log "$DEV missing, skip"; exit 0; }

CUR=$(cat $SYS/comp_algorithm 2>/dev/null)
case "$CUR" in
	*"[$ALGO]"*) log "already uses $ALGO, nothing to do"; exit 0 ;;
esac

SIZE=$(cat $SYS/disksize 2>/dev/null)
case "$SIZE" in
	''|*[!0-9]*) log "unexpected disksize '$SIZE', skip"; exit 0 ;;
esac
[ "$SIZE" -gt 0 ] || { log "disksize is 0, skip"; exit 0; }

ORIG=$(echo "$CUR" | sed -n 's/.*\[\([^]]*\)\].*/\1/p')
[ -n "$ORIG" ] || ORIG=lzo-rle

PRIO=$(awk -v d="$DEV" '$1 == d { print $5 }' /proc/swaps 2>/dev/null)
case "$PRIO" in
	''|*[!0-9]*) PRIO="" ;;
esac

log "start: current=[$ORIG] size=$SIZE prio=${PRIO:-default}"

swapon_dev() {
	if [ -n "$PRIO" ]; then
		swapon -p "$PRIO" "$DEV"
	else
		swapon "$DEV"
	fi
}

restore() {
	echo 1 > $SYS/reset 2>/dev/null
	echo "$ORIG" > $SYS/comp_algorithm 2>/dev/null
	echo "$SIZE" > $SYS/disksize 2>/dev/null
	mkswap "$DEV" >/dev/null 2>&1
	swapon_dev
	log "rolled back to [$ORIG], swapon rc=$?"
}

if grep -q "^$DEV" /proc/swaps 2>/dev/null; then
	swapoff "$DEV" || { log "swapoff failed, abort"; exit 0; }
fi

echo 1 > $SYS/reset 2>/dev/null || { log "reset failed"; swapon_dev; exit 0; }

if ! echo "$ALGO" > $SYS/comp_algorithm 2>/dev/null; then
	log "writing comp_algorithm=$ALGO failed"
	restore
	exit 0
fi

if ! echo "$SIZE" > $SYS/disksize 2>/dev/null; then
	log "writing disksize failed"
	restore
	exit 0
fi

mkswap "$DEV" >/dev/null 2>&1 || { log "mkswap failed"; restore; exit 0; }
swapon_dev || { log "swapon failed"; exit 0; }

CUR=$(cat $SYS/comp_algorithm 2>/dev/null)
SIZE_NOW=$(cat $SYS/disksize 2>/dev/null)
log "done: comp=[$CUR] disksize=$SIZE_NOW swap=$(awk -v d="$DEV" '$1 == d { print $4 }' /proc/swaps)"
