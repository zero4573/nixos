#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_dir="$HOME/.config/vicinae"
data_dir="$HOME/.local/share/vicinae"
tracked_dir="$repo_dir/modules/vicinae"

# vicinae writes settings.json as JSONC: `//` lines, then the JSON object from a line of just "{"
json_body() { sed -n '/^{/,$p' "$1"; }
jsonc_header() { sed -n '1,/^{/{/^{/!p}' "$1"; }

if [ -f "$config_dir/settings.json" ]; then
  repo_settings="$tracked_dir/settings.json"
  live_settings="$config_dir/settings.json"
  header="$(jsonc_header "$repo_settings")"
  merged="$(jq -s '.[0] * .[1]' <(json_body "$repo_settings") <(json_body "$live_settings"))"
  { printf '%s\n' "$header"; printf '%s\n' "$merged"; } > "$repo_settings"
  echo "Merged $repo_settings (repo as base, live system overriding conflicts)"
else
  echo "No live settings.json found at $config_dir/settings.json" >&2
fi

if [ -f "$data_dir/snippets/snippets.json" ]; then
  repo_snippets="$tracked_dir/snippets.json"
  live_snippets="$data_dir/snippets/snippets.json"
  # vicinae's snippets.json is an array keyed by each record's unique "id"
  jq -s '
    (.[0] | map({(.id): .}) | add // {}) as $base |
    (.[1] | map({(.id): .}) | add // {}) as $override |
    ($base * $override) | to_entries | map(.value)
  ' "$repo_snippets" "$live_snippets" > "$repo_snippets.tmp"
  mv "$repo_snippets.tmp" "$repo_snippets"
  echo "Merged $repo_snippets (repo as base, live system overriding conflicts by id)"
else
  echo "No live snippets.json found at $data_dir/snippets/snippets.json" >&2
fi

echo ""
echo "Review and commit:"
echo "  git -C \"$repo_dir\" diff -- modules/vicinae/"
