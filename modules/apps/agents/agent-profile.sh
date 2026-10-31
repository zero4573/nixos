# Agent accounts ("profiles"): sourced by every agent wrapper (claude, kiro,
# claude-open, kiro-open: modules/apps/claude, modules/apps/kiro) and by the
# agent / agent-open dispatcher. A profile is a name, an agent (claude or
# kiro) and a home directory holding that account's config and login:
#
#   ~/.config/agents/profiles.json (AGENTS_CONFIG), written by agent-configure:
#   { "default": "work-kiro",
#     "profiles": { "work-kiro": { "agent": "kiro", "home": "~/.config/agents/homes/work-kiro" } } }
#
# AGENT=<profile> picks one. A wrapper only takes a profile of its own agent,
# so a tool that starts a particular CLI (tix) works the same whichever
# account AGENT names. Without AGENT, or with AGENT naming another agent's
# profile, a wrapper uses its agent's default: the file's "default" when it
# is a profile of that agent, else that agent's only profile, else the
# CLI's usual home (~/.claude, ~/.kiro). AGENT=none always means the usual
# home.

agents_config() { printf '%s' "${AGENTS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/agents/profiles.json}"; }

# agents_expand <path>: ~ and $HOME expanded
agents_expand() {
  local p="$1"
  # shellcheck disable=SC2088,SC2016 # literal ~ and $HOME, expanded by hand
  case "$p" in
    "~"|"~/"*) p="$HOME${p#\~}" ;;
    '$HOME'|'$HOME/'*) p="$HOME${p#\$HOME}" ;;
  esac
  printf '%s' "$p"
}

agents_valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# agents_field <profile> <field>: the profile's field ("" when absent);
# fails when the file isn't valid JSON
agents_field() {
  local f
  f="$(agents_config)"
  [[ -f "$f" ]] || return 0
  if ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
    echo "agents: $f isn't a JSON object" >&2
    return 1
  fi
  jq -r --arg n "$1" --arg k "$2" '(.profiles[$n]?[$k]? // "") | if type == "string" then . else "" end' "$f"
}

# agent_default <agent>: the profile a wrapper of <agent> uses without
# AGENT: the file's default when it is a profile of <agent>, else <agent>'s
# only profile; "" when neither (the usual home)
agent_default() {
  local f
  f="$(agents_config)"
  [[ -f "$f" ]] || return 0
  jq -r --arg a "$1" '(.profiles // {}) as $p
    | ([$p | to_entries[] | select(.value.agent? == $a) | .key]) as $mine
    | if (.default | type) == "string" and $p[.default].agent? == $a then .default
      elif ($mine | length) == 1 then $mine[0]
      else "" end' "$f" 2>/dev/null || true
}

# agent_profile <agent>: exports AGENT_PROFILE and AGENT_HOME (absolute,
# created if missing) for the profile of <agent> to use: AGENT when it
# names one, else agent_default's; AGENT=none, or no profile of <agent>:
# nothing (the CLI's usual home). A profile of another agent is left alone
# (with a note). Fails, with a message, for a name that isn't a profile or
# a bad home.
agent_profile() {
  local want="$1" name="${AGENT:-}" agent home
  unset AGENT_PROFILE AGENT_HOME
  [[ "$name" == none ]] && return 0
  [[ -n "$name" ]] || name="$(agent_default "$want")"
  [[ -n "$name" ]] || return 0
  if ! agents_valid_name "$name"; then
    echo "agents: AGENT=$name isn't a profile name" >&2
    return 1
  fi
  agent="$(agents_field "$name" agent)" || return 1
  if [[ -z "$agent" ]]; then
    echo "agents: no profile '$name' in $(agents_config) (agent-configure adds one)" >&2
    return 1
  fi
  if [[ "$agent" != "$want" ]]; then
    name="$(agent_default "$want")"
    echo "agents: AGENT=${AGENT:-} is a $agent profile; $want uses ${name:-its usual home}" >&2
    [[ -n "$name" ]] || return 0
  fi
  home="$(agents_expand "$(agents_field "$name" home)")" || return 1
  if [[ "$home" != /* ]]; then
    echo "agents: profile '$name' has no absolute home ('$home')" >&2
    return 1
  fi
  mkdir -p "$home" && chmod 700 "$home"
  export AGENT_PROFILE="$name" AGENT_HOME="$home"
}
