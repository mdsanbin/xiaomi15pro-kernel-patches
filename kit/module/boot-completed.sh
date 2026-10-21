#!/system/bin/sh
# Record the final zram state after boot, so it is visible whether anything
# (e.g. Scene) reconfigured zram after our post-fs-data run.
MODDIR=${0%/*}
LOG=$MODDIR/tune.log
SYS=/sys/block/zram0

{
	echo "$(date '+%Y-%m-%d %H:%M:%S') [boot-completed] comp=$(cat $SYS/comp_algorithm 2>/dev/null)"
	echo "  swap: $(awk '$1 ~ /zram/ { print $1, $3, $4, $5 }' /proc/swaps 2>/dev/null)"
	echo "  mm_stat: $(cat $SYS/mm_stat 2>/dev/null)"
} >> "$LOG"
