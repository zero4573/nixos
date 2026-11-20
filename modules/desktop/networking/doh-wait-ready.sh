#!/usr/bin/env bash
set -euo pipefail

action="${2:-}"
[ "$action" = "pre-up" ] || exit 0
[ -n "${CONNECTION_UUID:-}" ] || exit 0

ignore="$(nmcli -g ipv4.ignore-auto-dns connection show "$CONNECTION_UUID" 2>/dev/null || echo no)"
[ "$ignore" = "yes" ] || exit 0

# NetworkManager blocks activation on pre-up hooks; on a fresh boot dnscrypt-proxy
# needs a few seconds to fetch its resolver list before it answers
for _ in $(seq 1 50); do
  dig +time=1 +tries=1 +short @127.0.0.1 -p 53 cloudflare.com >/dev/null 2>&1 && exit 0
  sleep 0.2
done
exit 0
