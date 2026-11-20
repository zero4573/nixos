#!/usr/bin/env bash

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
  (( delta_uj < 0 )) && delta_uj=$(( delta_uj + range )) # the RAPL counter wraps at max_energy_range_uj
  delta_us=$(( now_us - last_us ))
  last_uj="$uj"
  last_us="$now_us"
  (( delta_us > 0 )) || continue

  deciwatts=$(( (delta_uj * 10 + delta_us / 2) / delta_us ))
  history+=("$(( deciwatts / 10 )).$(( deciwatts % 10 ))")
  (( ${#history[@]} > max_samples )) && history=("${history[@]:1}")

  printf '%s\n' "${history[@]}" > "$out.tmp"
  mv -f "$out.tmp" "$out"
done
