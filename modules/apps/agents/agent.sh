# agent / agent-open: run the agent of an account (agent-profile.sh), the
# sandboxed or the open wrapper of its CLI (claude, kiro / claude-open,
# kiro-open), with AGENT set to the profile so the wrapper uses its home.
# The profile is $AGENT, else the file's default, else its only one. With no
# profiles yet, agent-configure sets one up first.
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
"default", else its only profile. With none yet, agent-configure sets one up.

  agent-configure           add a profile
  agent-configure --list    list them
  agent-configure --default <profile>
EOF
  exit 0
fi

profiles() {
  local f
  f="$(agents_config)"
  [[ -f "$f" ]] || return 0
  jq -r '.profiles // {} | keys[]' "$f" 2>/dev/null
}

if [[ -z "$(profiles)" ]]; then
  if [[ -t 0 ]]; then
    echo "$cmd_name: no agent profiles yet; setting one up" >&2
    "$AGENT_CONFIGURE" || exit 1
  else
    echo "$cmd_name: no agent profiles in $(agents_config); run agent-configure" >&2
    exit 1
  fi
fi

name="${AGENT:-}"
if [[ -z "$name" ]]; then
  name="$(jq -r '.default // "" | strings' "$(agents_config)" 2>/dev/null || true)"
fi
if [[ -z "$name" ]]; then
  mapfile -t all < <(profiles)
  if (( ${#all[@]} == 1 )); then
    name="${all[0]}"
  else
    echo "$cmd_name: set AGENT to one of: ${all[*]} (or a default: agent-configure --default <profile>)" >&2
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
