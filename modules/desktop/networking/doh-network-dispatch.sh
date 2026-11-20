#!/usr/bin/env bash
set -euo pipefail

action="${2:-}"
[ "$action" = "up" ] || exit 0
[ -n "${CONNECTION_UUID:-}" ] || exit 0

conn_type="$(nmcli -g connection.type connection show "$CONNECTION_UUID" 2>/dev/null || true)"
case "$conn_type" in
  802-11-wireless | 802-3-ethernet) ;;
  *) exit 0 ;;
esac

marker="/var/lib/doh-network-choice/$CONNECTION_UUID"
[ -e "$marker" ] && exit 0

# root has no session bus for notifications; NetworkManager needs dispatcher scripts to return quickly
systemctl -M "@nmDoHUser@@" --user start --no-block "doh-network-prompt@$CONNECTION_UUID.service" || true
