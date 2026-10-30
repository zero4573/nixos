# Lays out the current herdr tab around the pane it's run from (the
# focused pane when run outside one), splitting it rather than replacing
# the tab, so nothing already running is lost:
#   full    Claude | ttt over a shell, each half the width
#   simple  Claude | ttt
# The left pane is the existing one: claude is started in it only when it
# sits at a shell prompt, and is the sandboxed claude. ttt opens the left
# pane's directory.
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

split() {
  local args=("$1" --direction "$2" --ratio 0.5)
  [[ -n "$cwd" ]] && args+=(--cwd "$cwd")
  herdr pane split "${args[@]}" | jq -r '.result.pane.pane_id'
}

right="$(split "$base" right)"
herdr pane run "$right" "ttt . ../andy-ct" >/dev/null
if [[ "$mode" == full ]]; then
  split "$right" down >/dev/null
fi

# The sandboxed claude (claude-sandbox.nix) by its profile path, typed into
# the pane's shell, so another claude earlier on that shell's PATH can't
# start instead
claude=claude
profile_claude="/etc/profiles/per-user/${USER:-$(id -un)}/bin/claude"
[[ -x "$profile_claude" ]] && claude="$profile_claude"
case "$fg" in
  zsh | bash | sh | fish) herdr pane run "$base" "$claude" >/dev/null ;;
esac
