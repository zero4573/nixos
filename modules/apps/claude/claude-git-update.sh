dir="${1:-$PWD}"

git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

warn() {
  echo "claude: $*" >&2
}

if ! GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes" \
    timeout 30 git -C "$dir" fetch --prune --quiet 2>/dev/null; then
  warn "git fetch failed (offline or auth?), launching on the local checkout"
  exit 0
fi

branch="$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null)" || exit 0
upstream="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || exit 0

read -r ahead behind < <(git -C "$dir" rev-list --left-right --count 'HEAD...@{u}')
if [ "$behind" -eq 0 ]; then
  exit 0
fi
if [ "$ahead" -gt 0 ]; then
  warn "$branch has diverged from $upstream ($ahead ahead, $behind behind), not updating"
  exit 0
fi

if git -C "$dir" merge --ff-only --quiet '@{u}' >/dev/null 2>&1; then
  echo "claude: fast-forwarded $branch to $upstream ($behind commit(s))" >&2
else
  warn "couldn't fast-forward $branch to $upstream (local changes in the way?), launching on the local checkout"
fi
exit 0
