# Lays out the current herdr tab around the pane it's run from (the
# focused pane when run outside one), splitting it rather than replacing
# the tab, so nothing already running is lost:
#   full    Claude | ttt over two shells side by side, each half the
#           width; Claude (with --add-dir andy-tix), ttt and the left shell
#           in andy-nixos, the right shell in andy-tix
#   simple  Claude | ttt
# The left pane is the existing one: claude is started in it only when it
# sits at a shell prompt, and is the sandboxed claude. In simple, ttt opens
# the left pane's directory.
# Run as the local.layouts plugin's actions (herdr.nix).
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

# split PANE DIRECTION [CWD]: the new pane starts in CWD, else in the left
# pane's directory
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

# The sandboxed claude (claude-sandbox.nix) by its profile path, typed into
# the pane's shell, so another claude earlier on that shell's PATH can't
# start instead
claude=claude
profile_claude="/etc/profiles/per-user/${USER:-$(id -un)}/bin/claude"
[[ -x "$profile_claude" ]] && claude="$profile_claude"
# full: in andy-nixos, with andy-tix added, as ttt opens them
cmd="$(printf '%q' "$claude")"
if [[ "$mode" == full ]]; then
  cmd="cd $(printf '%q' "$repos/andy-nixos") && $cmd --add-dir $(printf '%q' "$repos/andy-tix")"
fi
case "$fg" in
  zsh | bash | sh | fish) herdr pane run "$base" "$cmd" >/dev/null ;;
esac
