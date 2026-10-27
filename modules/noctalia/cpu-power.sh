#!/usr/bin/env bash
# Publishes CPU package power for the noctalia cpu_power plugin. The RAPL
# energy counter is root-only because high-rate reads leak power-based timing
# to unprivileged code (CVE-2020-8694, "Platypus"); a 2s average rounded to
# 0.1W is far too coarse for that, so only this value is made world-readable.
#
#
# The out-file holds the last $CPU_POWER_HISTORY samples, oldest first, one
# per line. Keeping history here rather than in the plugin means a noctalia
# config reload (which rebuilds plugin widgets) redraws the full graph at once.
#
# Usage: cpu-power.sh <out-file>
#   (env: RAPL_ZONE, CPU_POWER_INTERVAL, CPU_POWER_HISTORY)

set -euo pipefail

out="$1"
zone="${RAPL_ZONE:-/sys/class/powercap/intel-rapl:0}"
interval="${CPU_POWER_INTERVAL:-2}"
max_samples="${CPU_POWER_HISTORY:-60}"
history=()

read -r range < "$zone/max_energy_range_uj"
read -r last_uj < "$zone/energy_uj"
last_us="${EPOCHREALTIME/./}"

while sleep "$interval"; do
  read -r uj < "$zone/energy_uj"
  now_us="${EPOCHREALTIME/./}"

  delta_uj=$(( uj - last_uj ))
  (( delta_uj < 0 )) && delta_uj=$(( delta_uj + range )) # counter wrapped
  delta_us=$(( now_us - last_us ))
  last_uj="$uj"
  last_us="$now_us"
  (( delta_us > 0 )) || continue

  # uJ per us is W; work in tenths of a watt, rounded
  tenths=$(( (delta_uj * 10 + delta_us / 2) / delta_us ))
  history+=("$(( tenths / 10 )).$(( tenths % 10 ))")
  (( ${#history[@]} > max_samples )) && history=("${history[@]:1}")

  printf '%s\n' "${history[@]}" > "$out.tmp"
  mv -f "$out.tmp" "$out"
done
