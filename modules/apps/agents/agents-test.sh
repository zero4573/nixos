#!/usr/bin/env bash
# Test of the agent profile scripts (agent-profile.sh, agent.sh,
# agent-configure.sh), put together as agents.nix does (the resolver
# inlined before each script), with stub wrappers that record what they are
# run with, in a throwaway HOME. Needs bash, jq, coreutils, util-linux
# (column). Usage: agents-test.sh [dir with the scripts] (default: this
# one's). Also a flake check, agents-check.nix.
set -euo pipefail

src="$(realpath "${1:-$(dirname "${BASH_SOURCE[0]}")}")"
root="$(realpath "$(mktemp -d)")"
trap 'rm -rf "$root"' EXIT
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
ok() { echo "ok: $*"; }

bin="$root/bin"
mkdir -p "$bin"
build() {  # build <name> <script> [exports...]: the resolver + the script
  local name="$1" script="$2"
  shift 2
  { printf '#!%s\nset -euo pipefail\n' "$BASH"; printf '%s\n' "$@"; cat "$src/agent-profile.sh" "$src/$script"; } > "$bin/$name"
  chmod +x "$bin/$name"
}
# shellcheck disable=SC2088 # a literal ~, expanded by agent-configure
build agent-configure agent-configure.sh 'export AGENTS_HOMES="~/.config/agents/homes"'
# Stub wrappers: what a claude / kiro wrapper does with the profile (the
# resolver, as the real ones run it), recorded
for a in claude kiro; do
  for m in sandbox open; do
    {
      printf '#!%s\nset -euo pipefail\n' "$BASH"
      cat "$src/agent-profile.sh"
      printf 'agent_profile %s\n' "$a"
      # shellcheck disable=SC2016 # the stub's own variables, expanded when it runs
      printf 'printf "%%s\\n" "%s-%s" "AGENT=${AGENT:-}" "AGENT_PROFILE=${AGENT_PROFILE:-}" "AGENT_HOME=${AGENT_HOME:-}" "$@" > "$OUT"\n' "$a" "$m"
    } > "$bin/stub-$a-$m"
    chmod +x "$bin/stub-$a-$m"
  done
done
for m in sandbox open; do
  n=agent
  [[ "$m" == open ]] && n=agent-open
  build "$n" agent.sh "export AGENTS_MODE=$m" "export AGENT_CONFIGURE=$bin/agent-configure" \
    "export AGENT_CMD_claude_sandbox=$bin/stub-claude-sandbox" "export AGENT_CMD_claude_open=$bin/stub-claude-open" \
    "export AGENT_CMD_kiro_sandbox=$bin/stub-kiro-sandbox" "export AGENT_CMD_kiro_open=$bin/stub-kiro-open"
done

export HOME="$root/home" XDG_CONFIG_HOME="$root/home/.config" OUT="$root/out"
unset AGENT AGENT_HOME AGENT_PROFILE AGENTS_CONFIG
mkdir -p "$HOME/.claude/skills/s" "$HOME/.kiro/agents" "$HOME/.kiro/settings"
echo '{"theme":"dark"}' > "$HOME/.claude/settings.json"
echo '{"chat.agentEngine":"v3"}' > "$HOME/.kiro/settings/cli.json"
cfg="$HOME/.config/agents/profiles.json"

# 1. No profiles: without a terminal agent says to run agent-configure
if ! "$bin/agent" </dev/null 2>"$root/err" && grep -q 'run agent-configure' "$root/err"; then
  ok "no profiles and no terminal: agent says to run agent-configure"
else
  fail "no profiles: $(cat "$root/err")"
fi

# 2. agent-configure adds a first profile (the default) with the defaults
printf 'work-kiro\n\n\n' | "$bin/agent-configure" 2>"$root/err" || fail "configure work-kiro: $(cat "$root/err")"
h="$HOME/.config/agents/homes/work-kiro"
if jq -e '.default == "work-kiro" and .profiles["work-kiro"] == {agent: "kiro", home: "~/.config/agents/homes/work-kiro"}' "$cfg" >/dev/null; then
  ok "configure: the first profile, agent guessed from its name, home under the homes dir, the default"
else
  fail "configure: $(cat "$cfg")"
fi
if [[ -L "$h/agents" && "$(readlink "$h/agents")" == "$HOME/.kiro/agents" && -f "$h/settings/cli.json" ]] \
  && jq -e '.profile == "work-kiro"' "$h/.agent-profile" >/dev/null && [[ "$(stat -c %a "$h")" == 700 ]]; then
  ok "configure: a kiro home links ~/.kiro's agents, copies its settings, is marked and private"
else
  fail "configure kiro home: $(ls -la "$h")"
fi

# 3. A second claude profile with its own home, not the default
printf 'personal\nclaude\n~/accounts/personal\nn\n' | "$bin/agent-configure" 2>"$root/err" || fail "configure personal: $(cat "$root/err")"
p="$HOME/accounts/personal"
if jq -e '.default == "work-kiro" and .profiles.personal == {agent: "claude", home: "~/accounts/personal"}' "$cfg" >/dev/null \
  && [[ -f "$p/settings.json" && ! -L "$p/settings.json" && -d "$p/skills/s" ]]; then
  ok "configure: a claude profile gets copies of ~/.claude's settings and skills"
else
  fail "configure claude: $(cat "$cfg"; ls -la "$p")"
fi
# a name that exists, a home in use or above $HOME are refused (no terminal: no retry)
if ! printf 'personal\n' | "$bin/agent-configure" 2>/dev/null \
  && ! printf 'other\nclaude\n~/accounts/personal\n' | "$bin/agent-configure" 2>/dev/null \
  && ! printf 'other\nclaude\n~\n' | "$bin/agent-configure" 2>/dev/null \
  && [[ "$(jq '.profiles | length' "$cfg")" == 2 ]]; then
  ok "configure: an existing name, a home in use and the home directory are refused"
else
  fail "configure refusals: $(cat "$cfg")"
fi
"$bin/agent-configure" --list > "$root/list"
if grep -qE '^\* +work-kiro +kiro' "$root/list" && grep -qE '^ +personal +claude' "$root/list"; then
  ok "configure --list marks the default"
else
  fail "list: $(cat "$root/list")"
fi

# 4. agent runs the default profile's sandboxed wrapper, agent-open its open one
"$bin/agent" chat -a
if [[ "$(sed -n 1p "$OUT")" == kiro-sandbox ]] && grep -qx 'AGENT=work-kiro' "$OUT" && grep -qx "AGENT_HOME=$h" "$OUT" \
  && grep -qx -- '-a' "$OUT"; then
  ok "agent: the default profile, its home and the arguments reach the kiro wrapper"
else
  fail "agent default: $(cat "$OUT")"
fi
AGENT=personal "$bin/agent-open" --resume
if [[ "$(sed -n 1p "$OUT")" == claude-open ]] && grep -qx "AGENT_HOME=$p" "$OUT"; then
  ok "agent-open: AGENT picks the profile and its open wrapper"
else
  fail "agent-open: $(cat "$OUT")"
fi
if ! AGENT=nope "$bin/agent" 2>"$root/err" && grep -q "no profile 'nope'" "$root/err"; then
  ok "agent: an unknown profile is refused"
else
  fail "agent unknown: $(cat "$root/err")"
fi
"$bin/agent-configure" --default personal >/dev/null
"$bin/agent"
if [[ "$(sed -n 1p "$OUT")" == claude-sandbox ]] && grep -qx 'AGENT=personal' "$OUT"; then
  ok "configure --default changes the profile agent uses"
else
  fail "default change: $(cat "$OUT")"
fi

# 5. The wrappers themselves: AGENT of their own agent picks the home; of the
# other agent, or unset, the usual one (how tix, which runs claude or kiro,
# gets the account)
AGENT=work-kiro "$bin/stub-claude-sandbox" 2>"$root/err"
if grep -qx 'AGENT_HOME=' "$OUT" && grep -q 'is a kiro profile' "$root/err"; then
  ok "wrapper: a profile of the other agent leaves the usual home"
else
  fail "wrapper other agent: $(cat "$OUT" "$root/err")"
fi
AGENT=personal "$bin/stub-claude-sandbox"
if grep -qx "AGENT_HOME=$p" "$OUT" && grep -qx 'AGENT_PROFILE=personal' "$OUT"; then
  ok "wrapper: a profile of its own agent sets AGENT_HOME"
else
  fail "wrapper own agent: $(cat "$OUT")"
fi
AGENT_HOME=/stale "$bin/stub-kiro-open"
if grep -qx 'AGENT_HOME=' "$OUT"; then
  ok "wrapper: no AGENT, no profile (a stale AGENT_HOME is dropped)"
else
  fail "wrapper no AGENT: $(cat "$OUT")"
fi
if ! AGENT=nope "$bin/stub-kiro-open" 2>/dev/null; then ok "wrapper: an unknown profile fails"; else fail "wrapper: unknown profile ran"; fi
echo 'not json' > "$cfg"
if ! AGENT=personal "$bin/stub-claude-open" 2>"$root/err" && grep -q "isn't a JSON object" "$root/err"; then
  ok "a broken profiles file is reported"
else
  fail "broken file: $(cat "$root/err")"
fi

if (( failures > 0 )); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all agents checks passed"
