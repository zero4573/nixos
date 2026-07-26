#!/usr/bin/env bash
# Pulls live Vicinae config (settings.json, snippets.json) into this project,
# merging rather than overwriting: the repo's tracked copy is the base, and
# the live system copy wins on any conflicting value. This way local-only
# tweaks committed to the repo survive a pull, while whatever changed live
# (via the GUI, or vicinae rewriting the file itself) still comes across.

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_dir="$HOME/.config/vicinae"
data_dir="$HOME/.local/share/vicinae"
tracked_dir="$repo_dir/modules/vicinae"

# settings.json is JSONC: a leading block of `//` comment lines (vicinae's
# own boilerplate explaining the file) followed by a plain JSON object
# starting at a line of just "{". Split those apart so jq can merge the
# JSON body, then reattach the comment header (taken from the repo copy,
# since it's the base).
json_body() { sed -n '/^{/,$p' "$1"; }
jsonc_header() { sed -n '1,/^{/{/^{/!p}' "$1"; }

if [ -f "$config_dir/settings.json" ]; then
  repo_settings="$tracked_dir/settings.json"
  live_settings="$config_dir/settings.json"
  header="$(jsonc_header "$repo_settings")"
  # jq's `*` deep-merges objects key by key, recursing into nested objects;
  # for arrays and scalars present in both sides, the right-hand (live)
  # value simply replaces the left-hand (repo) one -- exactly "repo as
  # base, system overriding conflicts".
  merged="$(jq -s '.[0] * .[1]' <(json_body "$repo_settings") <(json_body "$live_settings"))"
  { printf '%s\n' "$header"; printf '%s\n' "$merged"; } > "$repo_settings"
  echo "Merged $repo_settings (repo as base, live system overriding conflicts)"
else
  echo "No live settings.json found at $config_dir/settings.json" >&2
fi

if [ -f "$data_dir/snippets/snippets.json" ]; then
  repo_snippets="$tracked_dir/snippets.json"
  live_snippets="$data_dir/snippets/snippets.json"
  # snippets.json is an array of records, each with a unique "id" (see
  # vicinae's SerializedSnippet/SnippetDatabase) -- key both arrays by id
  # before merging, so repo-only and live-only snippets are both kept, and
  # a snippet present on both sides takes the live version.
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
