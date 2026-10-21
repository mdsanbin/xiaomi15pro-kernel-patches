#!/system/bin/sh
# Mi15 runtime tuning - runs at late_start service (after boot completed).
# Kernel side already provides CONFIG_WQ_POWER_EFFICIENT_DEFAULT=y and
# CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y, but Android init overrides THP to "never",
# so THP must be rewritten here.
MODDIR=${0%/*}
LOG=$MODDIR/tune.log

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 5; done
sleep 20

echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
echo 10 > /dev/cpuctl/top-app/cpu.uclamp.min 2>/dev/null
echo 60 > /dev/cpuctl/background/cpu.uclamp.max 2>/dev/null

{
  echo "$(date '+%Y-%m-%d %H:%M:%S') applied"
  echo "  thp      = $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)"
  echo "  top-app  = $(cat /dev/cpuctl/top-app/cpu.uclamp.min 2>/dev/null)"
  echo "  bg       = $(cat /dev/cpuctl/background/cpu.uclamp.max 2>/dev/null)"
  echo "  wq_pe    = $(cat /sys/module/workqueue/parameters/power_efficient 2>/dev/null)"
} >> "$LOG"
