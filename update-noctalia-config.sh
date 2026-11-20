#!/usr/bin/env bash

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

# noctalia config export merges every *.toml in the config dir with the state
# dir's settings.toml, so the config dir holds only gui.toml, not Nix's config.toml
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

if grep -q '/nix/store/' "$tracked_file"; then
  echo "" >&2
  echo "warning: gui.toml contains /nix/store paths (e.g. a wallpaper picked in the GUI):" >&2
  grep -n '/nix/store/' "$tracked_file" >&2
fi

echo ""
echo "Review and commit:"
echo "  git -C \"$repo_dir\" diff -- modules/noctalia/"
