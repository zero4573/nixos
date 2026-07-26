#!/usr/bin/env bash
# Pulls the live Vicinae snippets file back into the nix-tracked copy so
# snippets added via the GUI can be committed and carried to other hosts.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
live_file="$HOME/.local/share/vicinae/snippets/snippets.json"
tracked_file="$repo_dir/modules/vicinae/snippets.json"

if [ ! -f "$live_file" ]; then
  echo "No live snippets file found at $live_file" >&2
  exit 1
fi

nix run nixpkgs#jq -- . "$live_file" > "$tracked_file"

echo "Updated $tracked_file from $live_file."
echo "Review and commit:"
echo "  git -C \"$repo_dir\" diff -- modules/vicinae/snippets.json"
