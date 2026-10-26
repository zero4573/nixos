#!/usr/bin/env bash
# Test of claude-sandbox-self-check.sh: runs it against a temp root with stub
# tools first on PATH. Usage: claude-sandbox-self-check-test.sh [path to
# claude-sandbox-self-check.sh] (default: the sibling script). Also a flake
# check, claude-sandbox-check.nix. Needs bash, jq and coreutils.
set -euo pipefail

script="$(realpath "${1:-$(dirname "${BASH_SOURCE[0]}")/claude-sandbox-self-check.sh}")"
root="$(realpath "$(mktemp -d)")"
trap 'rm -rf "$root"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok: $*"; }

stubs="$root/stubs"
mkdir -p "$stubs"
for t in git jj ssh-keygen kill pkill killall rg nix; do
  printf '#!%s\nexit 0\n' "$BASH" > "$stubs/$t"
  chmod +x "$stubs/$t"
done
# jq and coreutils come from the real PATH, behind the stubs; the script gets
# jq by absolute path so a PATH without jq can be tested
SELF_CHECK_JQ="$(command -v jq)"
export SELF_CHECK_JQ
export SELF_CHECK_TOOLS="git jj ssh-keygen kill pkill killall rg jq nix"
export SELF_CHECK_RULES='["Bash(kill:*)","Bash(pkill:*)","Bash(killall:*)"]'
export SELF_CHECK_CONTAINER_MARKER="$root/containerenv"
export SELF_CHECK_SETTINGS="$root/managed-settings.json"
export SELF_CHECK_NIX_SOCKET="$root/no-socket"
touch "$SELF_CHECK_CONTAINER_MARKER"
good='{"permissions":{"allow":["Bash(killall:*)","Bash(kill:*)","Bash(pkill:*)"]}}'
echo "$good" > "$SELF_CHECK_SETTINGS"

# run <name> <expected rc> <expected output regex>: PATH is the stubs plus the
# real one
run() {
  local name="$1" want="$2" re="$3" out rc=0
  out="$(PATH="${TEST_PATH:-$stubs:$PATH}" "$BASH" "$script" 2>&1)" || rc=$?
  last_out="$out"
  if [[ "$rc" != "$want" ]]; then fail "$name: exit $rc, want $want: $out"
  elif ! grep -Eq "$re" <<< "$out"; then fail "$name: no match for /$re/: $out"
  else pass "$name"; fi
}

run "all present" 0 '^ok: managed settings'
if grep -Eq '^missing:' <<< "$last_out"; then
  fail "all present: unexpected missing line"
fi

export SELF_CHECK_TOOLS="$SELF_CHECK_TOOLS no-such-tool-xyz"
run "missing tool" 1 '^missing: no-such-tool-xyz'
export SELF_CHECK_TOOLS="git jj ssh-keygen kill pkill killall rg jq nix"

echo '{"permissions":{"allow":["Bash(kill:*)"]}}' > "$SELF_CHECK_SETTINGS"
run "too few rules" 1 '^missing: managed settings permissions.allow'
echo '{"permissions":{"allow":["Bash(kill:*)","Bash(pkill:*)","Bash(killall:*)","Bash(rm:*)"]}}' > "$SELF_CHECK_SETTINGS"
run "extra rule" 1 '^missing: managed settings permissions.allow'
echo '{}' > "$SELF_CHECK_SETTINGS"
run "no rules" 1 '^missing: managed settings permissions.allow'
rm "$SELF_CHECK_SETTINGS"
run "absent settings" 1 '^missing: .* not readable'
echo "$good" > "$SELF_CHECK_SETTINGS"

# S02: a PATH without jq reports it missing (the script's own jq is absolute)
mkdir "$root/nojq"
cp "$stubs"/* "$root/nojq/"
TEST_PATH="$root/nojq" run "no jq on PATH" 1 '^missing: jq not on PATH'
# S01: no external kill (only the bash builtin) reads as missing
mkdir "$root/nokill"
cp "$stubs"/* "$root/nokill/"
rm "$root/nokill/kill"
TEST_PATH="$root/nokill" run "builtin kill only" 1 '^missing: kill not on PATH'

# S04: unset lists are a usage error, not defaults
saved_tools="$SELF_CHECK_TOOLS"
unset SELF_CHECK_TOOLS
run "tools unset" 3 'usage error'
export SELF_CHECK_TOOLS="$saved_tools"
unset SELF_CHECK_RULES
run "rules unset" 3 'usage error'
export SELF_CHECK_RULES='["Bash(kill:*)","Bash(pkill:*)","Bash(killall:*)"]'

rm "$SELF_CHECK_CONTAINER_MARKER"
run "not in a container" 2 'not in the sandbox container'

if ((failures)); then echo "$failures failure(s)" >&2; exit 1; fi
echo "all passed"
