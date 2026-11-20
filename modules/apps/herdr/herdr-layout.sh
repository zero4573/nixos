set -euo pipefail

mode="${1:-}"
case "$mode" in
  full | simple) ;;
  *)
    echo "usage: herdr-layout full|simple" >&2
    exit 2
    ;;
esac

base="${HERDR_PANE_ID:-$(herdr pane current | jq -r '.result.pane.pane_id')}"
info="$(herdr pane process-info --pane "$base")"
cwd="$(jq -r '.result.process_info.foreground_processes[0].cwd // empty' <<<"$info")"
fg="$(jq -r '.result.process_info.foreground_processes[0].name // empty' <<<"$info")"

repos="$HOME/Projects/repo-work/bitbucket/streamsix"

split() {
  local dir="${3:-$cwd}"
  local args=("$1" --direction "$2" --ratio 0.5)
  [[ -n "$dir" ]] && args+=(--cwd "$dir")
  herdr pane split "${args[@]}" | jq -r '.result.pane.pane_id'
}

if [[ "$mode" == full ]]; then
  right="$(split "$base" right "$repos/andy-nixos")"
  shell="$(split "$right" down "$repos/andy-nixos")"
  split "$shell" right "$repos/andy-tix" >/dev/null
else
  right="$(split "$base" right)"
fi
herdr pane run "$right" "ttt . ../andy-tix" >/dev/null

claude=claude
profile_claude="/etc/profiles/per-user/${USER:-$(id -un)}/bin/claude"
[[ -x "$profile_claude" ]] && claude="$profile_claude"
cmd="$(printf '%q' "$claude")"
if [[ "$mode" == full ]]; then
  cmd="cd $(printf '%q' "$repos/andy-nixos") && $cmd --add-dir $(printf '%q' "$repos/andy-tix")"
fi
case "$fg" in
  zsh | bash | sh | fish) herdr pane run "$base" "$cmd" >/dev/null ;;
esac
