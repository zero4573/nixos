#!/usr/bin/env bash
set -euo pipefail

uuid="${1:?connection uuid required}"
name="$(nmcli -g connection.id connection show "$uuid" 2>/dev/null || echo "$uuid")"

# some notification daemons ignore --expire-time for notifications with actions
choice=""
choice="$(timeout 45 notify-send -w -a "DNS over HTTPS" \
  -A doh="Force DNS over HTTPS" \
  -A auto="Use this network's own DNS" \
  "New network: $name" \
  "Which DNS should this network use?")" || choice=""

if [ "$choice" = "auto" ]; then
  ignore=no
else
  ignore=yes
fi

nmcli connection modify "$uuid" ipv4.ignore-auto-dns "$ignore" ipv6.ignore-auto-dns "$ignore"

touch "/var/lib/doh-network-choice/$uuid"

if [ "$ignore" = yes ]; then
  # NetworkManager applies ignore-auto-dns on the next activation; the connection is already up
  nmcli connection up "$uuid" >/dev/null 2>&1 || true
fi
