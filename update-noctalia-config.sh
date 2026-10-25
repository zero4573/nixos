#!/usr/bin/env bash
# Pulls live Noctalia GUI changes (~/.local/state/noctalia/settings.toml) into
# the nix-tracked modules/noctalia/gui.toml so they can be committed and
# carried to other hosts, merging rather than overwriting: the repo's tracked
# copy is the base, and the live GUI overrides win on any conflicting value.
#
# The merge is done by noctalia itself: `noctalia config export` merges a
# config dir's *.toml files with the state dir's settings.toml, the same way
# the shell loads them. Pointing the config dir at a temp dir holding only
# gui.toml keeps the Nix-generated config.toml out of the result, and the
# export drops noctalia's internal config_version marker.

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
tracked_file="$repo_dir/modules/noctalia/gui.toml"

if [ ! -f "$state_home/noctalia/settings.toml" ]; then
  echo "No live settings.toml found at $state_home/noctalia/settings.toml" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/config/noctalia" "$tmp/check"
cp "$tracked_file" "$tmp/config/noctalia/gui.toml"

NOCTALIA_CONFIG_HOME="$tmp/config" NOCTALIA_STATE_HOME="$state_home" \
  noctalia config export > "$tmp/check/gui.toml"
noctalia config validate "$tmp/check" >/dev/null

{
  echo "# Noctalia GUI settings, pulled from ~/.local/state/noctalia/settings.toml"
  echo "# by update-noctalia-config.sh. Layers over the Nix-generated config.toml"
  echo "# (see noctalia.nix); remove a key here to hand it back to Nix."
  echo
  cat "$tmp/check/gui.toml"
} > "$tracked_file"

echo "Merged $tracked_file (repo as base, live GUI overriding conflicts)"

# Wallpapers picked from the repo's assets dir are stored as /nix/store
# paths, which go stale once the assets change.
if grep -q '/nix/store/' "$tracked_file"; then
  echo "" >&2
  echo "warning: gui.toml contains /nix/store paths (e.g. a wallpaper picked in the GUI):" >&2
  grep -n '/nix/store/' "$tracked_file" >&2
fi

echo ""
echo "Review and commit:"
echo "  git -C \"$repo_dir\" diff -- modules/noctalia/"
