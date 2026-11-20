# shellcheck disable=SC2016 # jq filters and their $variables, in single quotes

homes="$(agents_expand "${AGENTS_HOMES:-~/.config/agents/homes}")"
file="$(agents_config)"

usage() {
  cat <<EOF
Usage: agent-configure                      add a profile (asks for each value)
       agent-configure --agent claude|kiro  choose that agent's default profile, or add one
       agent-configure --default [<profile>]
                                            the profile agent / agent-open use without
                                            AGENT, and its agent's default
       agent-configure --list               list the profiles

Profiles are in $file. A profile is a name (AGENT=<name> picks it), an agent
(claude or kiro) and a home directory for that account's config and login
(default $homes/<name>). Without AGENT, claude and kiro use their agent's
default profile; with none, they run agent-configure --agent first. To use
~/.claude or ~/.kiro, add a profile with that home.
EOF
}

write_profiles() {
  local filter="$1" tmp
  shift
  mkdir -p "$(dirname "$file")"
  [[ -s "$file" ]] || echo '{"profiles":{}}' > "$file"
  tmp="$(mktemp "$file.XXXXXX")"
  if jq "$@" "$filter" "$file" > "$tmp"; then
    mv -f "$tmp" "$file"
  else
    rm -f "$tmp"
    echo "agent-configure: couldn't update $file" >&2
    return 1
  fi
}

tilde() { [[ "$1" == "$HOME" || "$1" == "$HOME"/* ]] && printf '~%s' "${1#"$HOME"}" || printf '%s' "$1"; }

ask() {
  local line
  if [[ -n "${2:-}" ]]; then printf '%s [%s]: ' "$1" "$2" >&2; else printf '%s: ' "$1" >&2; fi
  IFS= read -r line || { echo >&2; return 1; }
  printf '%s' "${line:-${2:-}}"
}
no_answer() { echo "agent-configure: no answer, nothing written" >&2; exit 1; }
yes() { [[ "${1,,}" =~ ^y(es)?$ ]]; }

profiles_of() {
  [[ -f "$file" ]] || return 0
  jq -r --arg a "${1:-}" '.profiles // {} | to_entries[] | select($a == "" or .value.agent == $a) | .key' "$file"
}

global_default() {
  local n
  [[ -f "$file" ]] || return 0
  n="$(jq -r '.default // "" | strings' "$file" 2>/dev/null)" || return 0
  [[ -n "$n" && -n "$(agents_field "$n" agent)" ]] && printf '%s' "$n"
  return 0
}

set_defaults() {
  write_profiles '.defaults[$a] = $n | if $g == "y" then .default = $n else . end' \
    --arg n "$1" --arg a "$(agents_field "$1" agent)" --arg g "$2"
}

add_profile() {
  local preset="${1:-}" name agent home used guess answer global=n mine=n login src f d
  while :; do
    name="$(ask "Profile name (e.g. work-${preset:-claude}, personal-${preset:-kiro})")" || no_answer
    if ! agents_valid_name "$name"; then
      echo "  letters, digits, '.', '_' and '-' only" >&2
    elif [[ -n "$(agents_field "$name" agent)" ]]; then
      echo "  '$name' exists already (agent-configure --list)" >&2
    else
      break
    fi
    [[ -t 0 ]] || exit 1
  done
  if [[ -n "$preset" ]]; then
    agent="$preset"
  else
    guess=claude
    [[ "$name" == *kiro* ]] && guess=kiro
    while :; do
      agent="$(ask "Agent (claude or kiro)" "$guess")" || no_answer
      [[ "$agent" == claude || "$agent" == kiro ]] && break
      echo "  claude or kiro" >&2
      [[ -t 0 ]] || exit 1
    done
  fi
  while :; do
    home="$(ask "Home directory" "$(tilde "$homes/$name")")" || no_answer
    home="$(agents_expand "$home")"
    home="${home%/}"
    used=""
    [[ -f "$file" ]] && used="$(jq -r --arg h "$(tilde "$home")" --arg a "$home" \
      '.profiles // {} | to_entries[] | select(.value.home == $h or .value.home == $a) | .key' "$file")"
    if [[ "$home" != /* ]]; then
      echo "  an absolute path (or ~/...)" >&2
    elif [[ -n "$used" ]]; then
      echo "  profile '$used' uses it already" >&2
    elif [[ "$HOME" == "$home" || "$HOME" == "$home"/* ]]; then
      # kiro ignores a KIRO_HOME that is or contains the home directory
      echo "  not your home directory or a folder above it" >&2
    else
      break
    fi
    [[ -t 0 ]] || exit 1
  done
  if [[ -n "$preset" || -z "$(agent_default "$agent" 2>/dev/null)" ]]; then
    mine=y
  else
    answer="$(ask "Use it for $agent when AGENT isn't set, instead of $(agent_default "$agent")? (y/N)" n)" || no_answer
    yes "$answer" && mine=y
  fi
  if [[ -z "$(global_default)" ]]; then
    global=y
  else
    answer="$(ask "Use it for agent / agent-open when AGENT isn't set, instead of $(global_default)? (y/N)" n)" || no_answer
    yes "$answer" && global=y
  fi

  mkdir -p "$home"
  chmod 700 "$home"
  case "$agent" in
    claude)
      src="$HOME/.claude"
      if [[ "$home" != "$src" ]]; then
        for f in settings.json CLAUDE.md; do
          [[ -f "$src/$f" && ! -e "$home/$f" ]] && cp "$src/$f" "$home/$f"
        done
        for d in skills agents; do
          [[ -d "$src/$d" && ! -e "$home/$d" ]] && cp -r "$src/$d" "$home/$d"
        done
      fi
      login="AGENT=$name agent-open, then /login" ;;
    kiro)
      src="$HOME/.kiro"
      if [[ "$home" != "$src" ]]; then
        for d in agents skills steering hooks powers; do
          [[ -d "$src/$d" && ! -e "$home/$d" ]] && ln -s "$src/$d" "$home/$d"
        done
        mkdir -p "$home/settings"
        for f in cli.json mcp.json; do
          [[ -f "$src/settings/$f" && ! -e "$home/settings/$f" ]] && cp "$src/settings/$f" "$home/settings/$f"
        done
      fi
      login="AGENT=$name agent-open login" ;;
  esac
  jq -n --arg n "$name" --arg a "$agent" '{profile: $n, agent: $a}' > "$home/.agent-profile"

  write_profiles '.profiles[$n] = {agent: $a, home: $h}
    | if $m == "y" then .defaults[$a] = $n else . end
    | if $g == "y" then .default = $n else . end' \
    --arg n "$name" --arg a "$agent" --arg h "$(tilde "$home")" --arg m "$mine" --arg g "$global"
  {
    printf 'agent-configure: added %s (%s, home %s)' "$name" "$agent" "$(tilde "$home")"
    [[ "$mine" == y ]] && printf ", %s's default" "$agent"
    [[ "$global" == y ]] && printf ", agent's default"
    printf '\n  log in once: %s\n  run it: AGENT=%s agent (sandboxed) or AGENT=%s agent-open\n' "$login" "$name" "$name"
  } >&2
  printf '%s' "$name"
}

choose() {
  local what="$1" list=() i answer
  mapfile -t list < <(profiles_of "${2:-}")
  (( ${#list[@]} > 0 )) || { printf ''; return 0; }
  echo "Profiles for $what:" >&2
  for i in "${!list[@]}"; do
    printf '  %d) %s (%s)\n' $((i + 1)) "${list[i]}" "$(agents_field "${list[i]}" home)" >&2
  done
  echo "  n) add a new one" >&2
  while :; do
    answer="$(ask "Which" 1)" || no_answer
    if [[ "$answer" == n || "$answer" == new ]]; then
      printf ''
      return 0
    elif [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#list[@]} )); then
      printf '%s' "${list[answer - 1]}"
      return 0
    fi
    echo "  1-${#list[@]} or n" >&2
    [[ -t 0 ]] || exit 1
  done
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --list)
    [[ -f "$file" ]] || { echo "no profiles yet ($file)"; exit 0; }
    echo "(* agent / agent-open's default; + its agent's default)"
    jq -r '(.default // "") as $d | (.defaults // {}) as $ds | .profiles // {} | to_entries[]
      | "\(if .key == $d then "*" else " " end)\(if $ds[.value.agent] == .key then "+" else " " end) \(.key)\t\(.value.agent)\t\(.value.home)"' "$file" | column -t -s $'\t'
    exit 0 ;;
  --agent)
    want="${2:-}"
    [[ "$want" == claude || "$want" == kiro ]] || { usage >&2; exit 1; }
    name="$(choose "$want when AGENT isn't set" "$want")"
    if [[ -z "$name" ]]; then
      echo "Adding a $want profile, $want's default:" >&2
      add_profile "$want" >/dev/null
    else
      set_defaults "$name" n
      echo "agent-configure: $want uses $name when AGENT isn't set" >&2
    fi
    exit 0 ;;
  --default)
    name="${2:-}"
    if [[ -z "$name" ]]; then
      name="$(choose "agent / agent-open when AGENT isn't set")"
      if [[ -z "$name" ]]; then
        add_profile >/dev/null
        exit 0
      fi
    fi
    [[ -n "$(agents_field "$name" agent)" ]] || { echo "agent-configure: no profile '$name'" >&2; exit 1; }
    set_defaults "$name" y
    echo "agent-configure: agent / agent-open and $(agents_field "$name" agent) use $name when AGENT isn't set" >&2
    exit 0 ;;
  "") add_profile >/dev/null; exit 0 ;;
  *) usage >&2; exit 1 ;;
esac
