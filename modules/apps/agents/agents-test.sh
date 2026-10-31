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
      # a terminal only when the case says so (STUB_TTY=1)
      # shellcheck disable=SC2016 # the stub's own variable, expanded when it runs
      printf 'agents_interactive() { [[ "${STUB_TTY:-}" == 1 ]]; }\n'
      printf 'export AGENT_CONFIGURE=%q\n' "$bin/agent-configure"
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
if jq -e '.default == "work-kiro" and .defaults == {kiro: "work-kiro"} and .profiles["work-kiro"] == {agent: "kiro", home: "~/.config/agents/homes/work-kiro"}' "$cfg" >/dev/null; then
  ok "configure: the first profile, agent guessed from its name, home under the homes dir, the default and kiro's"
else
  fail "configure: $(cat "$cfg")"
fi
if [[ -L "$h/agents" && "$(readlink "$h/agents")" == "$HOME/.kiro/agents" && -f "$h/settings/cli.json" ]] \
  && jq -e '.profile == "work-kiro"' "$h/.agent-profile" >/dev/null && [[ "$(stat -c %a "$h")" == 700 ]]; then
  ok "configure: a kiro home links ~/.kiro's agents, copies its settings, is marked and private"
else
  fail "configure kiro home: $(ls -la "$h")"
fi

# 3. A second, claude profile with its own home: claude's default (it has
# none yet), not agent's (asked: no)
printf 'personal\nclaude\n~/accounts/personal\nn\n' | "$bin/agent-configure" 2>"$root/err" || fail "configure personal: $(cat "$root/err")"
p="$HOME/accounts/personal"
if jq -e '.default == "work-kiro" and .defaults == {kiro: "work-kiro", claude: "personal"} and .profiles.personal == {agent: "claude", home: "~/accounts/personal"}' "$cfg" >/dev/null \
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
if grep -qE '^\*\+ +work-kiro +kiro' "$root/list" && grep -qE '^ \+ +personal +claude' "$root/list"; then
  ok "configure --list marks agent's default and each agent's"
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

# 5. The wrappers themselves (how tix, which runs claude or kiro, gets the
# account): AGENT of their own agent picks the home; without AGENT, or with
# another agent's profile, their agent's "defaults" entry; nothing guessed:
# with none, agent-configure --agent in a terminal, else a failure;
# AGENT=none is no profile. Here defaults: claude personal, kiro work-kiro.
"$bin/stub-claude-sandbox"
if grep -qx "AGENT_HOME=$p" "$OUT" && grep -qx 'AGENT_PROFILE=personal' "$OUT"; then
  ok "wrapper: no AGENT, its agent's default"
else
  fail "wrapper default: $(cat "$OUT")"
fi
"$bin/stub-kiro-open"
if grep -qx "AGENT_HOME=$h" "$OUT"; then
  ok "wrapper: kiro's own default, whatever agent / agent-open's is"
else
  fail "wrapper kiro default: $(cat "$OUT")"
fi
AGENT=work-kiro "$bin/stub-claude-sandbox" 2>"$root/err"
if grep -qx "AGENT_HOME=$p" "$OUT" && grep -q 'is a kiro profile; claude uses its own default' "$root/err"; then
  ok "wrapper: a profile of the other agent gives its own agent's default"
else
  fail "wrapper other agent: $(cat "$OUT" "$root/err")"
fi
AGENT=personal "$bin/stub-claude-sandbox"
if grep -qx "AGENT_HOME=$p" "$OUT" && grep -qx 'AGENT_PROFILE=personal' "$OUT"; then
  ok "wrapper: a profile of its own agent sets AGENT_HOME"
else
  fail "wrapper own agent: $(cat "$OUT")"
fi
AGENT_HOME=/stale "$bin/stub-claude-open"
if grep -qx "AGENT_HOME=$p" "$OUT"; then
  ok "wrapper: a stale AGENT_HOME in the environment is replaced"
else
  fail "wrapper stale: $(cat "$OUT")"
fi
rm -f "$OUT"
if ! AGENT=none "$bin/stub-claude-open" </dev/null 2>"$root/err" && [[ ! -e "$OUT" ]] && grep -q "no profile 'none'" "$root/err"; then
  ok "wrapper: AGENT=none isn't a way back to the usual home"
else
  fail "wrapper none: $(cat "$root/err")"
fi
# no kiro default, no terminal: it fails and says what to run (no guess,
# though work-kiro is the only kiro profile)
jq 'del(.defaults.kiro)' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
rm -f "$OUT"
if ! "$bin/stub-kiro-open" </dev/null 2>"$root/err" && [[ ! -e "$OUT" ]] && grep -q 'run agent-configure --agent kiro' "$root/err"; then
  ok "wrapper: no default for its agent and no terminal: fails, naming agent-configure --agent"
else
  fail "wrapper no default: $(cat "$root/err")"
fi
# in a terminal it runs agent-configure --agent kiro: choose a profile...
printf '1\n' | STUB_TTY=1 "$bin/stub-kiro-open" 2>"$root/err"
if grep -qx "AGENT_HOME=$h" "$OUT" && jq -e '.defaults.kiro == "work-kiro"' "$cfg" >/dev/null && grep -q '1) work-kiro' "$root/err"; then
  ok "wrapper: no default in a terminal: agent-configure --agent lists its profiles, the chosen one is used and kept"
else
  fail "wrapper choose: $(cat "$OUT" "$root/err")"
fi
# ...or add one (its agent's default; not asked which agent)
jq 'del(.defaults.kiro)' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
printf 'n\nother-kiro\n\nn\n' | STUB_TTY=1 "$bin/stub-kiro-open" 2>"$root/err"
o="$HOME/.config/agents/homes/other-kiro"
if grep -qx "AGENT_HOME=$o" "$OUT" && jq -e '.defaults.kiro == "other-kiro" and .profiles["other-kiro"].agent == "kiro" and .default == "personal"' "$cfg" >/dev/null; then
  ok "wrapper: or adds a profile of its agent, which becomes its default"
else
  fail "wrapper add: $(cat "$OUT" "$root/err"; cat "$cfg")"
fi
# a default naming another agent's profile isn't used
jq '.defaults.claude = "work-kiro"' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
if ! "$bin/stub-claude-open" </dev/null 2>"$root/err" && grep -q "defaults.claude .* names 'work-kiro', which isn't a claude profile" "$root/err"; then
  ok "wrapper: a default of the wrong agent is reported, not used"
else
  fail "wrapper wrong default: $(cat "$root/err")"
fi
"$bin/agent-configure" --agent claude <<< 1 2>/dev/null
if jq -e '.defaults.claude == "personal"' "$cfg" >/dev/null; then
  ok "configure --agent claude chooses claude's default"
else
  fail "configure --agent: $(cat "$cfg")"
fi
# agent / agent-open: no default and no terminal: fails (no guess)
jq 'del(.default)' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
if ! "$bin/agent" </dev/null 2>"$root/err" && grep -q 'no default profile' "$root/err"; then
  ok "agent: no default and no terminal: fails, naming agent-configure"
else
  fail "agent no default: $(cat "$root/err")"
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
