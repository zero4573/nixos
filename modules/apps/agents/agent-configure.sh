# agent-configure: add agent profiles (accounts) to profiles.json, one per
# run, by asking for each value (agent-profile.sh describes the file). Also
# --list and --default <profile>. A new profile's home gets a
# .agent-profile marker and a start from the usual one: Claude's
# settings.json, CLAUDE.md, skills and agents copied from ~/.claude (Nix
# keeps the copies of marked homes current at every switch); for kiro, links
# to ~/.kiro's agents, skills, steering, hooks and powers and a copy of its
# cli.json and mcp.json. Its login is its own: log in once with
# AGENT=<profile> agent-open.
#
# Set by the Nix wrapper: AGENTS_HOMES (where new homes go by default).
# shellcheck disable=SC2016 # jq filters and their $variables, in single quotes

homes="$(agents_expand "${AGENTS_HOMES:-~/.config/agents/homes}")"
file="$(agents_config)"

usage() {
  cat <<EOF
Usage: agent-configure                      add a profile (asks for each value)
       agent-configure --list               list the profiles
       agent-configure --default <profile>  the profile agent / agent-open use without AGENT

Profiles are in $file. A profile is a name (AGENT=<name> picks it), an agent
(claude or kiro) and a home directory for that account's config and login
(default $homes/<name>).
EOF
}

# write_profiles <jq filter> [jq args...]: the file through the filter
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

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --list)
    [[ -f "$file" ]] || { echo "no profiles yet ($file)"; exit 0; }
    jq -r '(.default // "") as $d | .profiles // {} | to_entries[]
      | "\(if .key == $d then "*" else " " end) \(.key)\t\(.value.agent)\t\(.value.home)"' "$file" | column -t -s $'\t'
    exit 0 ;;
  --default)
    name="${2:-}"
    [[ -n "$(agents_field "$name" agent)" ]] || { echo "agent-configure: no profile '$name'" >&2; exit 1; }
    write_profiles '.default = $n' --arg n "$name"
    echo "agent-configure: default profile is $name"
    exit 0 ;;
  "") ;;
  *) usage >&2; exit 1 ;;
esac

# ask <prompt> [default]: prints a line from stdin (the default for an
# empty one); fails at the end of input
ask() {
  local line
  if [[ -n "${2:-}" ]]; then printf '%s [%s]: ' "$1" "$2" >&2; else printf '%s: ' "$1" >&2; fi
  IFS= read -r line || { echo >&2; return 1; }
  printf '%s' "${line:-${2:-}}"
}
no_answer() { echo "agent-configure: no answer, nothing written" >&2; exit 1; }

while :; do
  name="$(ask "Profile name (e.g. work-claude, personal-kiro)")" || no_answer
  if ! agents_valid_name "$name"; then
    echo "  letters, digits, '.', '_' and '-' only" >&2
  elif [[ -n "$(agents_field "$name" agent)" ]]; then
    echo "  '$name' exists already (agent-configure --list)" >&2
  else
    break
  fi
  [[ -t 0 ]] || exit 1
done

guess=claude
[[ "$name" == *kiro* ]] && guess=kiro
while :; do
  agent="$(ask "Agent (claude or kiro)" "$guess")" || no_answer
  [[ "$agent" == claude || "$agent" == kiro ]] && break
  echo "  claude or kiro" >&2
  [[ -t 0 ]] || exit 1
done

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

make_default=y
if [[ -f "$file" && -n "$(jq -r '.profiles // {} | keys[]' "$file")" ]]; then
  answer="$(ask "Use it when AGENT isn't set? (y/N)" n)" || no_answer
  [[ "${answer,,}" =~ ^y(es)?$ ]] || make_default=n
fi

mkdir -p "$home"
chmod 700 "$home"
# The usual config to start from, unless the home is the usual one itself
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

write_profiles '.profiles[$n] = {agent: $a, home: $h} | if $d == "y" then .default = $n else . end' \
  --arg n "$name" --arg a "$agent" --arg h "$(tilde "$home")" --arg d "$make_default"
echo "agent-configure: added $name ($agent, home $(tilde "$home"))$( [[ "$make_default" == y ]] && echo ", the default")" >&2
echo "  log in once: $login" >&2
echo "  run it: AGENT=$name agent (sandboxed) or AGENT=$name agent-open" >&2
