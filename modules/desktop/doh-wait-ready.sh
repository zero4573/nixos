#!/usr/bin/env bash
# NetworkManager pre-up hook (runs as root; BLOCKS activation until it
# returns). Connections forced onto DoH (ignore-auto-dns=yes) have 
# dnscrypt-proxy as their ONLY resolver. On a fresh boot dnscrypt-proxy 
# needs a few seconds to fetch its resolver list and pick an upstream DoH 
# server before it can actually answer queries,
#
# Bounded to 10s and fails open (exit 0 regardless) so a broken
# dnscrypt-proxy can't block networking entirely.
set -euo pipefail

action="${2:-}"
[ "$action" = "pre-up" ] || exit 0
[ -n "${CONNECTION_UUID:-}" ] || exit 0

ignore="$(nmcli -g ipv4.ignore-auto-dns connection show "$CONNECTION_UUID" 2>/dev/null || echo no)"
[ "$ignore" = "yes" ] || exit 0

for _ in $(seq 1 50); do
  dig +time=1 +tries=1 +short @127.0.0.1 -p 53 cloudflare.com >/dev/null 2>&1 && exit 0
  sleep 0.2
done
exit 0
