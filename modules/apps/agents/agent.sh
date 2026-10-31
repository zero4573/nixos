# agent / agent-open: run the agent of an account (agent-profile.sh), the
# sandboxed or the open wrapper of its CLI (claude, kiro / claude-open,
# kiro-open), with AGENT set to the profile so the wrapper uses its home.
# The profile is $AGENT, else the file's default; with neither (no profiles
# yet, or no default), agent-configure adds or chooses one first.
#
# Set by the Nix wrapper: AGENTS_MODE (sandbox | open), AGENT_CONFIGURE (the
# agent-configure command), AGENT_CMD_<agent>_<mode> (each wrapper).

mode="${AGENTS_MODE:-sandbox}"
cmd_name=agent
[[ "$mode" == open ]] && cmd_name="agent-open"

if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
  cat <<EOF
Usage: [AGENT=<profile>] $cmd_name [agent args...]

Runs the agent of a profile (an account: agent + home directory, listed in
$(agents_config)) $( [[ "$mode" == open ]] && echo "unsandboxed (claude-open, kiro-open)" || echo "in its sandbox (claude, kiro)" ),
with every argument passed to it. The profile is \$AGENT, else the file's
"default"; with neither, agent-configure adds or chooses one first.

  agent-configure                      add a profile
  agent-configure --list               list them
  agent-configure --default [<profile>]
  agent-configure --agent claude|kiro  what claude / kiro use without AGENT
EOF
  exit 0
fi

profiles() {
  local f
  f="$(agents_config)"
  [[ -f "$f" ]] || return 0
  jq -r '.profiles // {} | keys[]' "$f" 2>/dev/null
}

default() {
  local n
  n="$(jq -r '.default // "" | strings' "$(agents_config)" 2>/dev/null || true)"
  [[ -n "$n" && -n "$(agents_field "$n" agent 2>/dev/null)" ]] && printf '%s' "$n"
  return 0
}

name="${AGENT:-}"
[[ -n "$name" ]] || name="$(default)"
# Nothing is guessed: with no profiles yet, or no default, agent-configure
# adds one or chooses the default (in a terminal)
if [[ -z "$name" ]]; then
  if [[ -t 0 ]]; then
    if [[ -z "$(profiles)" ]]; then
      echo "$cmd_name: no agent profiles yet; setting one up" >&2
      "$AGENT_CONFIGURE" || exit 1
    else
      echo "$cmd_name: no default profile; choose one" >&2
      "$AGENT_CONFIGURE" --default || exit 1
    fi
    name="$(default)"
  fi
  if [[ -z "$name" ]]; then
    echo "$cmd_name: no default profile in $(agents_config): run agent-configure (--default), or set AGENT=<profile>" >&2
    exit 1
  fi
fi

agents_valid_name "$name" || { echo "$cmd_name: '$name' isn't a profile name" >&2; exit 1; }
agent="$(agents_field "$name" agent)" || exit 1
case "$agent" in
  claude|kiro) ;;
  "") echo "$cmd_name: no profile '$name' (profiles: $(profiles | paste -sd' '))" >&2; exit 1 ;;
  *) echo "$cmd_name: profile '$name' has an unknown agent '$agent' (claude or kiro)" >&2; exit 1 ;;
esac
var="AGENT_CMD_${agent}_${mode}"
cmd="${!var:-}"
[[ -n "$cmd" ]] || { echo "$cmd_name: no $mode command for $agent" >&2; exit 1; }
export AGENT="$name"
exec "$cmd" "$@"
