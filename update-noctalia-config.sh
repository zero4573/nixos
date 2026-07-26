#!/usr/bin/env bash
# Pulls live Noctalia config (settings.json, plugins.json) back into the
# nix-tracked noctalia.json so changes made via the UI (bar layout, enabled
# plugins, etc.) can be committed and carried to other hosts.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_dir="$HOME/.config/noctalia"
tracked_file="$repo_dir/modules/noctalia/noctalia.json"

if [ ! -f "$config_dir/settings.json" ]; then
  echo "No live settings.json found at $config_dir/settings.json" >&2
  exit 1
fi
if [ ! -f "$config_dir/plugins.json" ]; then
  echo "No live plugins.json found at $config_dir/plugins.json" >&2
  exit 1
fi

# wallpaper.enabled/directory are force-overridden at seed-time by
# noctalia.nix (pinned to the repo's assets dir), so the live file always
# reflects that override rather than the repo's real intent -- pulling them
# back verbatim would bake the nix store path into noctalia.json. Every
# other wallpaper field (transitions, favorites, etc.) still syncs normally.
jq \
  --slurpfile settings "$config_dir/settings.json" \
  --slurpfile plugins "$config_dir/plugins.json" \
  '
    .settings.wallpaper as $trackedWallpaper
    | .settings = ($settings[0] | .wallpaper.enabled = $trackedWallpaper.enabled | .wallpaper.directory = $trackedWallpaper.directory)
    | .pluginRegistry = $plugins[0]
  ' \
  "$tracked_file" > "$tracked_file.tmp"
mv "$tracked_file.tmp" "$tracked_file"

echo "Updated $tracked_file from live Noctalia config."
echo "Review and commit:"
echo "  git -C \"$repo_dir\" diff -- modules/noctalia/noctalia.json"
