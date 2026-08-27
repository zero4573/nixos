#!/usr/bin/env bash
# NetworkManager dispatcher hook (runs as root). On "up" for a wifi/ethernet
# connection we haven't already asked about, bridges into the user's session
# to prompt whether this network should be forced onto DNS-over-HTTPS or use
# its own (auto) DNS
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

# Root has no session bus of its own to show a notification on, bridge
# into the user's own systemd --user session, where the notification daemon
# actually lives. --no-block: dispatcher scripts must return quickly, the
# prompt itself runs independently as a user service.
systemctl -M "@nmDoHUser@@" --user start --no-block "doh-network-prompt@$CONNECTION_UUID.service" || true
