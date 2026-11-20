agents_config() { printf '%s' "${AGENTS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/agents/profiles.json}"; }

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

agents_interactive() { [[ -t 0 ]]; }

agent_default() {
  local f n a
  f="$(agents_config)"
  [[ -f "$f" ]] || return 0
  n="$(jq -r --arg a "$1" '(.defaults[$a]? // "") | strings' "$f" 2>/dev/null)" || n=""
  [[ -n "$n" ]] || return 0
  a="$(agents_field "$n" agent)" || return 1
  if [[ "$a" != "$1" ]]; then
    echo "agents: defaults.$1 in $f names '$n', which isn't a $1 profile" >&2
    return 0
  fi
  printf '%s' "$n"
}

agent_profile() {
  local want="$1" name="${AGENT:-}" agent home
  unset AGENT_PROFILE AGENT_HOME
  if [[ -n "$name" ]]; then
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
      echo "agents: AGENT=$name is a $agent profile; $want uses its own default" >&2
      name=""
    fi
  fi
  if [[ -z "$name" ]]; then
    name="$(agent_default "$want")" || return 1
  fi
  if [[ -z "$name" ]] && agents_interactive && [[ -n "${AGENT_CONFIGURE:-}" ]]; then
    echo "agents: no $want profile chosen for when AGENT isn't set; choose or add one" >&2
    "$AGENT_CONFIGURE" --agent "$want" || return 1
    name="$(agent_default "$want")" || return 1
  fi
  if [[ -z "$name" ]]; then
    echo "agents: no $want profile chosen for when AGENT isn't set: run agent-configure --agent $want, or set AGENT=<profile>" >&2
    return 1
  fi
  home="$(agents_expand "$(agents_field "$name" home)")" || return 1
  if [[ "$home" != /* ]]; then
    echo "agents: profile '$name' has no absolute home ('$home')" >&2
    return 1
  fi
  mkdir -p "$home" && chmod 700 "$home"
  [[ "$want" == claude ]] && agents_claude_seed "$home/.claude.json"
  export AGENT_PROFILE="$name" AGENT_HOME="$home"
}

agents_claude_seed() {
  local f="$1" c=""
  [[ -f "$f" ]] && c="$(<"$f")"
  c="${c//[[:space:]]/}"
  [[ -z "$c" || "$c" == "{}" ]] || return 0
  printf '%s\n' '{"hasCompletedOnboarding":true,"theme":"dark","shiftEnterKeyBindingInstalled":true}' > "$f"
  chmod 600 "$f"
}
