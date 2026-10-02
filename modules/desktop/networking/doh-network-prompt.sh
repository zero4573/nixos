#!/usr/bin/env bash
# Runs in the user's session (invoked cross-user by the root dispatcher hook,
# see doh-network-dispatch.sh). Prompts whether the given connection should
# be forced onto DNS-over-HTTPS or use its own (auto) DNS, applies the
# choice, and records it so the network is never asked about again.
set -euo pipefail

uuid="${1:?connection uuid required}"
name="$(nmcli -g connection.id connection show "$uuid" 2>/dev/null || echo "$uuid")"

# timeout wraps notify-send itself rather than trusting -t/--expire-time,
# since some notification daemons ignore the client-requested timeout for
# notifications with actions attached (and won't auto-dismiss them). A
# non-zero/empty result (declined, dismissed, killed by timeout) falls
# through to "yes", forcing the use of DoH rather than silently
# leaving a new network on plaintext DNS if nobody answers.
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

# State dir is root:networkmanager 0775 (see tmpfiles rule), so this needs
# no sudo -- membership in the networkmanager group is enough either way.
touch "/var/lib/doh-network-choice/$uuid"

if [ "$ignore" = yes ]; then
  # The connection already came up on auto-dns before we could ask, so force
  # a reconnect for the choice to take effect now rather than next time.
  # Marker is already written above, so this reconnect won't re-prompt.
  nmcli connection up "$uuid" >/dev/null 2>&1 || true
fi
