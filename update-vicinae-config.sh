#!/usr/bin/env bash
# Pulls live Vicinae config (settings.json, snippets.json) back into the
# nix-tracked copies so changes made via the GUI can be committed and
# carried to other hosts.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_dir="$HOME/.config/vicinae"
data_dir="$HOME/.local/share/vicinae"
tracked_dir="$repo_dir/modules/vicinae"

# settings.json is JS-with-comments, not strict JSON -- copy verbatim rather
# than reformatting through jq (which would choke on the comments anyway).
if [ -f "$config_dir/settings.json" ]; then
  cp "$config_dir/settings.json" "$tracked_dir/settings.json"
  echo "Updated $tracked_dir/settings.json"
else
  echo "No live settings.json found at $config_dir/settings.json" >&2
fi

if [ -f "$data_dir/snippets/snippets.json" ]; then
  jq . "$data_dir/snippets/snippets.json" > "$tracked_dir/snippets.json"
  echo "Updated $tracked_dir/snippets.json"
else
  echo "No live snippets.json found at $data_dir/snippets/snippets.json" >&2
fi

echo ""
echo "Review and commit:"
echo "  git -C \"$repo_dir\" diff -- modules/vicinae/"
