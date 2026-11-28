#!/bin/bash
# linux-fullrun.sh: every job measured again (--force) with the aligning allocator, under
# zstrata's custom GPU profile (GFXCLK min active 3300 MHz). The card goes back to auto /
# profile 0 at the end, also when interrupted.
G=$(for c in /sys/class/drm/card?; do [ "$(cat $c/device/device)" = 0x7550 ] && echo $c/device; done)
restore() { echo auto > $G/power_dpm_force_performance_level; echo 0 > $G/pp_power_profile_mode; }
trap restore EXIT INT TERM
cd "$(dirname "$0")/.." && . ~/workspace/zstrata/tools/env.sh
echo "${PROFILE:-6 0 0 4 3300 4 800 4587520 -65536 0}" > $G/pp_power_profile_mode || exit 1
sleep 5
echo "governor $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor) epp $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference) load $(cut -d' ' -f1-3 /proc/loadavg)"
for g in D S M V; do zig-out/bin/zstrata-bench run $g --force "$@" || exit 1; done
