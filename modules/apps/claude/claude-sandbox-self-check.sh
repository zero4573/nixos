#!/usr/bin/env bash
set -euo pipefail

marker="${SELF_CHECK_CONTAINER_MARKER:-/run/.containerenv}"
settings="${SELF_CHECK_SETTINGS:-/etc/claude-code/managed-settings.json}"
socket="${SELF_CHECK_NIX_SOCKET:-/nix/var/nix/daemon-socket/socket}"
jq="${SELF_CHECK_JQ:-jq}"
timeout_cmd="${SELF_CHECK_TIMEOUT:-timeout}"

if [[ -z "${SELF_CHECK_TOOLS:-}" || -z "${SELF_CHECK_RULES:-}" ]]; then
  echo "usage error: SELF_CHECK_TOOLS and SELF_CHECK_RULES must be set" >&2
  exit 3
fi
tools="$SELF_CHECK_TOOLS"
rules="$SELF_CHECK_RULES"

if [[ ! -e "$marker" ]]; then
  echo "not in the sandbox container ($marker is absent): nothing to check"
  exit 2
fi
echo "ok: running in a container"

missing=0

for tool in $tools; do
  if path="$(type -P "$tool")"; then
    echo "ok: $tool on PATH ($path)"
  else
    echo "missing: $tool not on PATH"
    missing=1
  fi
done

# shellcheck disable=SC2016 # the jq program is not shell
if [[ ! -r "$settings" ]]; then
  echo "missing: $settings not readable"
  missing=1
elif ! actual="$("$jq" -c '.permissions.allow' "$settings" 2>/dev/null)"; then
  echo "missing: $settings is not valid JSON"
  missing=1
elif "$jq" -n -e --argjson a "$actual" --argjson e "$rules" \
  '($a | type) == "array" and ($a | sort) == ($e | sort)' > /dev/null; then
  echo "ok: managed settings permissions.allow is exactly $rules"
else
  echo "missing: managed settings permissions.allow is $actual, expected $rules"
  missing=1
fi

if [[ -S "$socket" ]] && command -v nix > /dev/null &&
  "$timeout_cmd" 10 nix store info --store daemon > /dev/null 2>&1; then
  echo "info: nix daemon answering"
else
  echo "info: nix daemon not answering"
fi

exit "$missing"
