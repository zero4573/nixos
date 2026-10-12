# Launch log: every step is timestamped (seconds since launch) on stderr --
# --quiet keeps only warnings there -- and always appended to
# ~/.local/state/claude-sandbox.log, so a launch that hangs shows which step
# it's stuck in (tail -f that file from another terminal)
launch_log="${XDG_STATE_HOME:-$HOME/.local/state}/claude-sandbox.log"
mkdir -p "$(dirname "$launch_log")"
if [[ "$(stat -c %s "$launch_log" 2>/dev/null || echo 0)" -gt 5242880 ]]; then
  tail -c 1048576 "$launch_log" > "$launch_log.tmp" && mv "$launch_log.tmp" "$launch_log"
fi
launch_start="${EPOCHREALTIME//[.,]/}"
quiet=0
log_line() {
  local now ms
  now="${EPOCHREALTIME//[.,]/}"
  ms=$(( (now - launch_start) / 1000 ))
  printf 'claude-sandbox [%d.%ds] %s\n' $((ms / 1000)) $(((ms % 1000) / 100)) "$1"
  printf '%s [%s] %s\n' "$(date -Iseconds)" "${pod_name:-pid $$}" "$1" >> "$launch_log" 2>/dev/null || true
}
log() {
  if [[ "$quiet" == 1 ]]; then
    log_line "$*" >/dev/null
  else
    log_line "$*" >&2
  fi
}
warn() {
  log_line "warning: $*" >&2
}


# Every argument belongs to claude and is passed through untouched; the
# sandbox only reads the ones that say what the session may touch (see
# "Mounts" below). Settings of the sandbox itself come from the environment:
#   CLAUDE_SANDBOX_PORTS        comma-separated ports to publish on the same
#                               host port, e.g. 3000,5173
#   CLAUDE_SANDBOX_NAME         pod label instead of <repo>-<folder>
#   CLAUDE_SANDBOX_QUIET=1      only warnings while launching
#   CLAUDE_SANDBOX_NO_GRAPHIFY=1  no graphify sidecar for this session
#   CLAUDE_SANDBOX_PASS_ENV     space-separated globs of host environment
#                               variables to pass in, e.g. "CLAUDE_TICKETS_*"
if [[ "${CLAUDE_SANDBOX_AS:-}" == claude-sandbox && "${1:-}" =~ ^(-h|--help)$ ]]; then
  cat <<'EOF'
Usage: claude [claude args...]        (claude-sandbox is the same command)

Runs Claude Code inside a sandboxed, privileged rootless podman container,
scoped to the current directory. The arguments are claude's own and are
passed through untouched (claude --help lists them); claude-open runs the
unsandboxed CLI.

What the session can see and change follows Claude's own settings:
  * read-write: the current directory and every --add-dir directory (from
    the arguments, and permissions.additionalDirectories in the user,
    project and --settings settings)
  * read-only: the paths of Edit(...) / Write(...) deny rules in those
    settings, when they lie inside a read-write directory; the most
    specific path wins, so a deny inside an --add-dir directory, or an
    --add-dir inside a denied one, works as expected. Rule paths follow
    Claude's syntax (//abs, ~/home, relative); * globs are expanded at
    launch, a ** in the middle of a path isn't
  * files named by --settings, --mcp-config, --plugin-dir and the
    --*system-prompt-file flags, read-only
  * /nix/store, ~/.claude (its settings, skills and agents read-only), and
    any vault's .obsidian/ read-only

Sandbox settings (environment):
  CLAUDE_SANDBOX_PORTS=3000,5173   publish ports on the same host ports
  CLAUDE_SANDBOX_NAME=<label>      pod claude-sandbox-<label>
  CLAUDE_SANDBOX_QUIET=1           only print warnings while launching
  CLAUDE_SANDBOX_NO_GRAPHIFY=1     skip the graphify sidecar (it's also
                                   skipped when an --mcp-config already
                                   defines a graphify server)
  CLAUDE_SANDBOX_PASS_ENV="A_* B"  host variables to pass in (name globs)

If the current directory is a git checkout, it is fetched and fast-forwarded
to its upstream before launch; diverged branches or local changes in the
way are reported and left alone. Each launch step is printed with the
seconds since launch, and logged to ~/.local/state/claude-sandbox.log.
EOF
  exit 0
fi

[[ "${CLAUDE_SANDBOX_QUIET:-}" == 1 ]] && quiet=1
port_flags=()
IFS=',' read -ra ports <<< "${CLAUDE_SANDBOX_PORTS:-}"
for p in "${ports[@]}"; do
  [[ -n "$p" ]] || continue
  if ! [[ "$p" =~ ^[0-9]+$ ]]; then
    echo "claude-sandbox: CLAUDE_SANDBOX_PORTS must be a comma-separated list of numbers: $p" >&2
    exit 1
  fi
  port_flags+=(-p "$p:$p")
done
graphify_enabled=1
[[ "${CLAUDE_SANDBOX_NO_GRAPHIFY:-}" == 1 ]] && graphify_enabled=0
name_override="${CLAUDE_SANDBOX_NAME:-}"

# The arguments the sandbox reads (never changes): --add-dir (variadic, like
# claude's), --settings (a file or a JSON string), --mcp-config (variadic,
# files or JSON strings), and flags naming files claude reads
add_dirs=() settings_args=() mcp_args=() path_args=()
args=("$@")
i=0
take_list() {  # take_list <array name>: the values after a variadic flag
  local -n into="$1"
  while (( i + 1 < ${#args[@]} )) && [[ "${args[i + 1]}" != -* ]]; do
    i=$((i + 1))
    into+=("${args[i]}")
  done
}
while (( i < ${#args[@]} )); do
  a="${args[i]}"
  case "$a" in
    --) break ;;
    --add-dir=*) add_dirs+=("${a#*=}") ;;
    --add-dir) take_list add_dirs ;;
    --mcp-config=*) mcp_args+=("${a#*=}") ;;
    --mcp-config) take_list mcp_args ;;
    --settings=*) settings_args+=("${a#*=}") ;;
    --settings) i=$((i + 1)); settings_args+=("${args[i]:-}") ;;
    --plugin-dir=*|--append-system-prompt-file=*|--system-prompt-file=*) path_args+=("${a#*=}") ;;
    --plugin-dir|--append-system-prompt-file|--system-prompt-file) i=$((i + 1)); path_args+=("${args[i]:-}") ;;
  esac
  i=$((i + 1))
done
project_root="$PWD"
log "launching in $project_root (log: $launch_log)"

# Fast-forward a git checkout to its upstream before anything else, so the
# graphify sidecar's startup build and watch begin on the updated tree
if git -C "$project_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "updating the git checkout (git fetch, at most 30s)"
  "$CLAUDE_GIT_UPDATE" "$project_root"
fi
asdf_data_dir="$HOME/.asdf"

# Consolidated exit cleanup
cleanup() {
  local code=$?
  if [[ -z "${claude_started:-}" ]]; then
    log "launch aborted (exit $code)"
  else
    log_line "session ended (exit $code)" >/dev/null
  fi
  [[ -n "${dbus_proxy_pid:-}" ]] && kill "$dbus_proxy_pid" 2>/dev/null || true
  [[ -n "${pod_name:-}" ]] && podman pod rm -f -t 5 "$pod_name" >/dev/null 2>&1 || true
  [[ -n "${tmp_dir:-}" && -d "$tmp_dir" ]] && rm -rf "$tmp_dir"
  [[ -n "${dbus_proxy_dir:-}" && -d "$dbus_proxy_dir" ]] && rm -rf "$dbus_proxy_dir"
}
trap cleanup EXIT

# claude-code is built with the system (programs.claudeSandbox.package, from
# the flake's locked nixpkgs), so launching evaluates and downloads nothing
claude_out="$CLAUDE_CODE"
log "claude-code: $claude_out"

# Claude's own auth/session state
mkdir -p "$HOME/.claude"
touch "$HOME/.claude.json"

network_flags=()
registry_env_flags=()
mounts=()
tmp_dir="$(mktemp -d)"
# sandbox-proxy (modules/apps/sandbox-proxy) holds the real credentials on
# the host; the sandbox only gets credential-free URLs on its networks
proxy_registry=0
proxy_mcp=0
if command -v sandbox-proxy >/dev/null 2>&1; then
  sandbox-proxy configured && proxy_registry=1
  sandbox-proxy mcp-configured && proxy_mcp=1
  if [[ "$proxy_registry" == 1 || "$proxy_mcp" == 1 ]]; then
    log "starting sandbox-proxy (registry=$proxy_registry mcp=$proxy_mcp; reuses running containers, may wait for 1Password or another launch's start)"
    sandbox-proxy start
    log "sandbox-proxy ready"
  fi
fi

# MCP servers (e.g. Jira/Bitbucket via Atlassian Rovo), reached through
# mcp-proxy on the sandbox-mcp network, which injects the auth headers
proxy_mcp_config=""
if [[ "$proxy_mcp" == 1 ]]; then
  network_flags+=(--network sandbox-mcp)
  proxy_mcp_config="$(sandbox-proxy sandbox-mcp-config)"
  log "MCP servers from sandbox-proxy: $(jq -r '.mcpServers | keys | join(", ")' <<< "$proxy_mcp_config" 2>/dev/null)"
fi

if [[ "$proxy_registry" == 1 ]]; then
  network_flags+=(--network sandbox-registry)

  if npmrc_line="$(sandbox-proxy sandbox-npmrc 2>/dev/null)"; then
    echo "$npmrc_line" > "$tmp_dir/.npmrc"
    mounts+=(-v "$tmp_dir/.npmrc:$HOME/.npmrc:ro")
  fi

  if goproxy_url="$(sandbox-proxy sandbox-goproxy 2>/dev/null)"; then
    registry_env_flags+=(-e "GOPROXY=$goproxy_url")
  fi

  if docker_prefix="$(sandbox-proxy sandbox-docker-prefix 2>/dev/null)"; then
    registry_env_flags+=(-e "REGISTRY_MIRROR_PREFIX=$docker_prefix")
  fi

  if extra_host="$(sandbox-proxy sandbox-extra-host 2>/dev/null)"; then
    network_flags+=(--add-host "$extra_host")
  fi
fi

# DBus notification proxy: xdg-dbus-proxy sits between the container and the 
# real bus, and only allows calls to org.freedesktop.Notifications. The
# filtered socket is then bind-mounted in, allowing for safe use of dbus for
# notifications in the sandboxed environment
dbus_mounts=()
dbus_env_flags=()
real_bus_address="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
if [[ "$real_bus_address" == unix:path=* || "$real_bus_address" == unix:abstract=* ]]; then
  dbus_proxy_dir="$(mktemp -d)"
  dbus_proxy_socket="$dbus_proxy_dir/notify-bus"

  log "starting the DBus notification proxy (at most 25s)"
  xdg-dbus-proxy "$real_bus_address" "$dbus_proxy_socket" \
    --filter \
    --talk=org.freedesktop.Notifications &
  dbus_proxy_pid=$!

  for _ in $(seq 1 50); do
    [[ -S "$dbus_proxy_socket" ]] && break
    sleep 0.5
  done

  if [[ -S "$dbus_proxy_socket" ]]; then
    dbus_mounts+=(-v "$dbus_proxy_socket:$dbus_proxy_socket")
    dbus_env_flags+=(-e "DBUS_SESSION_BUS_ADDRESS=unix:path=$dbus_proxy_socket")
  else
    warn "DBus notification proxy didn't come up, sandbox notifications will be unavailable"
    kill "$dbus_proxy_pid" 2>/dev/null || true
    dbus_proxy_pid=""
  fi
fi

# Claude and the graphify sidecar share one pod, and with it a network
# namespace, so the sidecar's MCP endpoint is reachable on Claude's
# localhost without being published anywhere else. Ports and networks are
# set on the pod.
#
# Everything is named after the git repo (origin's URL, else the first
# remote) plus the checkout folder, e.g. claude-sandbox-billing-service-db4005a08
# for a clone/worktree in ./db4005a08, or just the folder when it matches the
# repo name or there's no remote. A -2, -3, ... suffix keeps concurrent
# sessions in the same checkout apart. Labels make them filterable:
#   podman ps --filter label=claude-sandbox.repo=<repo>
sanitize_name() {
  tr '[:upper:]' '[:lower:]' <<< "$1" | sed -E 's/[^a-z0-9_.-]+/-/g; s/^[-_.]+//; s/[-_.]+$//'
}
remote_url="$(git -C "$project_root" remote get-url origin 2>/dev/null || true)"
if [[ -z "$remote_url" ]]; then
  first_remote="$(git -C "$project_root" remote 2>/dev/null | head -n1 || true)"
  [[ -n "$first_remote" ]] && remote_url="$(git -C "$project_root" remote get-url "$first_remote" 2>/dev/null || true)"
fi
repo_name="${remote_url%/}"
repo_name="${repo_name%.git}"
repo_name="$(sanitize_name "${repo_name##*[/:]}")"
folder_name="$(sanitize_name "$(basename "$project_root")")"
if [[ -n "$name_override" ]]; then
  name_base="$(sanitize_name "$name_override")"
elif [[ -n "$repo_name" && "$repo_name" != "$folder_name" ]]; then
  name_base="$repo_name-$folder_name"
else
  name_base="${folder_name:-project}"
fi
# The pod name doubles as its hostname, which is capped at 63 characters
# (leaving room for a -N suffix)
name_base="claude-sandbox-$name_base"
name_base="${name_base:0:58}"
name_base="${name_base%[-_.]}"

name_labels=(
  --label "claude-sandbox.project=$project_root"
  --label "claude-sandbox.repo=${repo_name:-}"
)
# Pods of sessions that died without cleaning up (killed, terminal closed,
# reboot) keep their graphify sidecar running. Remove the ones whose claude
# container is gone and that are over 10 minutes old (a new session's pod
# legitimately runs only its sidecar for minutes while the graph builds).
# (podman calls hang when another podman process holds its storage lock, so
# this is where a stuck podman first shows)
log "podman: checking for orphaned claude-sandbox pods"
now="$(date +%s)"
while read -r old_pod created; do
  [[ -n "$old_pod" && "$created" =~ ^[0-9]+$ ]] || continue
  [[ "$(podman inspect -f '{{.State.Running}}' "$old_pod-claude" 2>/dev/null)" == true ]] && continue
  (( now - created > 600 )) || continue
  podman pod rm -f -t 0 "$old_pod" >/dev/null 2>&1 \
    && log "removed the orphaned pod $old_pod"
done < <(podman pod ps --filter label=claude-sandbox.project --format '{{.Name}} {{.Created.Unix}}' 2>/dev/null || true)

# Containers go in aisandbox.slice (modules/apps/ai-sandbox-slice.nix) for
# its CPU, IO and memory limits; podman only honours that through the pod's
# cgroup parent, not through the systemd-run scope around the podman CLI
cgroup_flags=(--cgroup-parent=aisandbox.slice)
pod_name=""
n=1
log "podman: creating the pod"
while [[ -z "$pod_name" ]]; do
  candidate="$name_base"
  [[ "$n" -gt 1 ]] && candidate="$name_base-$n"
  n=$((n + 1))
  podman pod exists "$candidate" && continue
  if create_err="$(podman pod create --name "$candidate" --infra-name "$candidate-infra" \
      "${cgroup_flags[@]}" \
      "${name_labels[@]}" \
      "${port_flags[@]}" \
      "${network_flags[@]}" 2>&1 >/dev/null)"; then
    pod_name="$candidate"
  elif grep -qi "cgroup" <<< "$create_err" && [[ ${#cgroup_flags[@]} -gt 0 ]]; then
    warn "can't place the pod in aisandbox.slice ($create_err); continuing without its limits"
    cgroup_flags=()
    n=$((n - 1))
  elif ! grep -qi "already" <<< "$create_err"; then
    # Not a name clash but a real failure (e.g. a --ports conflict)
    warn "couldn't create pod $candidate: $create_err"
    exit 1
  fi
done
log "pod $pod_name"

# graphify sidecar: builds a code graph of the project into ./graphify-out
# (local tree-sitter, no LLM), keeps it current, and serves it to Claude as
# an MCP server.
graphify_mcp_config=""

# Preflight: is there any source file graphify's code-only pass can parse,
# in the same file set it would scan -- git's view (tracked + untracked,
# minus ignored) in a git checkout, otherwise a walk that prunes graphify's
# default skip dirs? No parseable code means no sidecar.
# Extensions mirror graphify.detect.CODE_EXTENSIONS for the pinned
# graphifyVersion (minus .json, which on its own isn't worth a graph) --
# refresh this list when bumping it.
graphify_code_re='\.(F|F03|F08|F90|F95|asd|astro|bash|c|cbl|cc|cjs|cl|cls|cob|cobol|cpp|cpy|cs|cshtml|csproj|cts|cu|cuh|cxx|dart|dfm|dm|dme|dmf|dmi|dmm|dpk|dpr|ejs|erl|escript|ets|ex|exs|f|f03|f08|f90|f95|fsproj|go|gradle|groovy|h|hcl|hpp|hrl|inc|java|jl|js|jsx|kt|kts|lfm|lisp|lpk|lpr|lsp|lua|luau|m|metal|mjs|ml|mli|mm|mts|pas|php|pp|ps1|psd1|psm1|py|r|rake|razor|rb|resource|robot|rs|scala|sh|sln|slnx|sol|sql|sv|svelte|svh|swift|tf|tfvars|toc|trigger|ts|tsx|v|vb|vbproj|vue|xaml|zig)$'
has_graphify_sources() {
  if git -C "$project_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$project_root" ls-files -z --cached --others --exclude-standard -- . 2>/dev/null
  else
    find "$project_root" -mindepth 1 \
      \( -type d \( -name node_modules -o -name venv -o -name .venv -o -name __pycache__ \
        -o -name dist -o -name build -o -name target -o -name site-packages -o -name lib64 \
        -o -name graphify-out -o -name '*.egg-info' -o -name '.*' \) -prune \) \
      -o -type f -print0 2>/dev/null
  fi | grep -zqE "$graphify_code_re"
}

# A session that already brings a graphify MCP server (--mcp-config, e.g.
# a merged graph of several repos) doesn't need the repo sidecar
if [[ "$graphify_enabled" == 1 ]]; then
  for m in "${mcp_args[@]}"; do
    if [[ "$m" == \{* ]]; then json="$m"; else json="$(cat "$m" 2>/dev/null || true)"; fi
    if jq -e '.mcpServers.graphify' >/dev/null 2>&1 <<< "$json"; then
      log "graphify: the session brings its own graphify server, skipping the sidecar"
      graphify_enabled=0
      break
    fi
  done
fi
if [[ "$graphify_enabled" == 1 ]]; then
  log "graphify: looking for source files it can parse"
  if ! has_graphify_sources; then
    log "graphify: no source files it can parse here, skipping the sidecar"
    graphify_enabled=0
  fi
fi

if [[ "$graphify_enabled" == 1 ]]; then
  graphify_port=47100
  graphify_key="$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')"
  log "graphify: starting the sidecar (pulls its image on first use)"
  systemd-run --user --scope --quiet --collect --slice=aisandbox.slice -- \
  podman run -d --rm \
    --name "$pod_name-graphify" \
    --pod "$pod_name" \
    "${name_labels[@]}" \
    --label claude-sandbox.role=graphify \
    --pull=missing \
    -v claude-sandbox-graphify:/opt/graphify \
    -v "$GRAPHIFY_SIDECAR:/sidecar.sh:ro" \
    -v "$GRAPHIFY_INSTALL:/graphify-install.sh:ro" \
    -v "$project_root:$project_root:rw" \
    -v "$GRAPHIFY_LOCK:/graphify-requirements.txt:ro" \
    -e GRAPHIFY_PORT="$graphify_port" \
    -e GRAPHIFY_API_KEY="$graphify_key" \
    -e PROJECT_ROOT="$project_root" \
    -e GRAPHIFY_QUERY_LOG_DISABLE=1 \
    "$GRAPHIFY_IMAGE" \
    sh /sidecar.sh >/dev/null
  # First run pip-installs graphify and the first graph build of a large
  # repo can take a while, so wait for the MCP endpoint before starting Claude,
  # reporting the last line of the sidecar's log every 15s meanwhile
  log "graphify: waiting for the MCP server, at most 5 min; installing graphify and building the code graph can take minutes on a large or first-time project (--no-graphify skips it, podman logs -f $pod_name-graphify follows it)"
  graphify_ready=0
  for i in $(seq 1 300); do
    if [[ "$(podman inspect -f '{{.State.Running}}' "$pod_name-graphify" 2>/dev/null)" != true ]]; then
      warn "graphify: the sidecar exited"
      break
    fi
    if (( i % 15 == 0 )); then
      log "graphify: still waiting; sidecar: $(podman logs --tail 1 "$pod_name-graphify" 2>&1 | tail -n1 | cut -c1-160)"
    fi
    if podman exec "$pod_name-graphify" python3 -c \
        'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1)' \
        "$graphify_port" 2>/dev/null; then
      graphify_ready=1
      break
    fi
    sleep 1
  done

  if [[ "$graphify_ready" == 1 ]]; then
    log "graphify: ready"
    graphify_mcp_config="{\"mcpServers\":{\"graphify\":{\"type\":\"http\",\"url\":\"http://127.0.0.1:$graphify_port/mcp\",\"headers\":{\"Authorization\":\"Bearer $graphify_key\"}}}}"
  else
    warn "graphify: the sidecar didn't come up, continuing without it:"
    podman logs --tail 20 "$pod_name-graphify" >&2 2>&1 || true
    podman rm -f -t 0 "$pod_name-graphify" >/dev/null 2>&1 || true
  fi
fi

# All MCP servers go into one file passed as --mcp-config=<file>: the flag
# is variadic, so a separate value would swallow a following positional
# prompt as another config file. claude merges it with any --mcp-config of
# the caller.
mcp_flags=()
if [[ -n "$proxy_mcp_config$graphify_mcp_config" ]]; then
  printf '%s\n' "$proxy_mcp_config" "$graphify_mcp_config" \
    | jq -s '{mcpServers: (map(select(. != null) | .mcpServers) | add)}' > "$tmp_dir/mcp.json"
  mounts+=(-v "$tmp_dir/mcp.json:$tmp_dir/mcp.json:ro")
  mcp_flags+=("--mcp-config=$tmp_dir/mcp.json")
fi

# Mounts, from Claude's own view of what the session may touch:
#  * read-write: the project and each --add-dir directory, from the
#    arguments and from permissions.additionalDirectories in the user,
#    project and --settings settings
#  * read-only: the paths of the Edit/Write/NotebookEdit deny rules in those
#    settings, but only inside a read-write directory (a deny elsewhere just
#    stays a permission rule: mounting it would expose it)
# The most specific path is mounted last, so it wins: ~/Projects read-only,
# a clone's .git read-write inside it, its .git/config read-only again.
settings_sources=()  # "<base dir>\t<json>": where relative rule paths start
add_settings() {
  local json
  json="$(cat "$2" 2>/dev/null || true)"
  [[ -n "$json" ]] && jq -e . >/dev/null 2>&1 <<< "$json" \
    && settings_sources+=("$1"$'\t'"$json")
  return 0
}
add_settings "$HOME/.claude" "$HOME/.claude/settings.json"
add_settings "$project_root" "$project_root/.claude/settings.json"
add_settings "$project_root" "$project_root/.claude/settings.local.json"
for s in "${settings_args[@]}"; do
  if [[ "$s" == \{* ]]; then
    jq -e . >/dev/null 2>&1 <<< "$s" && settings_sources+=("$project_root"$'\t'"$s")
  else
    add_settings "$project_root" "$s"
    path_args+=("$s")
  fi
done

# A path of a Claude rule or setting, made absolute: //abs, ~/home, /x
# relative to the settings' base, anything else relative to the project
abs_path() {  # abs_path <path> <base>
  local p="$1"
  case "$p" in
    //*) p="${p#/}" ;;
    "~"|"~/"*) p="$HOME${p#\~}" ;;
    /*) p="$2$p" ;;
    *) p="$project_root/$p" ;;
  esac
  realpath -m "$p"
}

rw_paths=("$(realpath -m "$project_root")")
for d in "${add_dirs[@]}"; do
  [[ "$d" == /* || "$d" == "~"* ]] || d="$PWD/$d"
  [[ "$d" == "~"* ]] && d="$HOME${d#\~}"
  if [[ -d "$d" ]]; then
    rw_paths+=("$(realpath "$d")")
  else
    warn "--add-dir $d isn't a directory, not mounting it"
  fi
done
ro_paths=()
for src in "${settings_sources[@]}"; do
  base="${src%%$'\t'*}"
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    d="$(abs_path "$d" "$base")"
    [[ -d "$d" ]] && rw_paths+=("$d")
  done < <(jq -r '.permissions.additionalDirectories[]? // empty' <<< "${src#*$'\t'}")
  while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue
    rule="${rule%/\*\*}"
    rule="${rule%/\*}"
    if [[ "$rule" == *"**"* ]]; then
      log "mounts: '$rule' has a ** inside the path, left to the permission rule"
      continue
    fi
    rule="$(abs_path "$rule" "$base")"
    if [[ "$rule" == *[*?[]* ]]; then
      # shellcheck disable=SC2206 # the glob is meant to expand
      local_matches=($rule)
      for m in "${local_matches[@]}"; do [[ -e "$m" ]] && ro_paths+=("$m"); done
    elif [[ -e "$rule" ]]; then
      ro_paths+=("$rule")
    fi
  done < <(jq -r '.permissions.deny[]? // empty
    | capture("^(Edit|Write|NotebookEdit)\\((?<p>.+)\\)$")?.p // empty' <<< "${src#*$'\t'}")
done

# within <path> <dir>...: true when <path> is one of the dirs or inside one
within() {
  local p="$1" d
  shift
  for d in "$@"; do
    [[ "$p" == "$d" || "$p" == "$d"/* ]] && return 0
  done
  return 1
}

# One mount per path (podman refuses two on the same destination, and
# orders them by depth itself, so the more specific path ends up on top);
# read-only wins over read-write on the same path
project_abs="$(realpath -m "$project_root")"
project_mode=rw
declare -A mount_mode=()
for p in "${rw_paths[@]}"; do
  [[ "$p" == "$project_abs" ]] || mount_mode[$p]=rw
done
for p in "${ro_paths[@]}"; do
  within "$p" "${rw_paths[@]}" || continue
  if [[ "$p" == "$project_abs" ]]; then
    project_mode=ro
  else
    mount_mode[$p]=ro
  fi
done

# A git directory given read-write on its own (e.g. a main clone's .git, so
# the session can add worktrees to it) keeps its config and hooks read-only:
# from there a session could run code on the host the next time git runs in
# that clone. (hooks/ is created first, or the session could create it.)
for p in "${!mount_mode[@]}"; do
  [[ "${mount_mode[$p]}" == rw && "$(basename "$p")" == .git ]] || continue
  mkdir -p "$p/hooks"
  mount_mode[$p/hooks]=ro
  [[ -f "$p/config" ]] && mount_mode[$p/config]=ro
done

# Files claude is told to read (settings, MCP configs, plugins, prompt
# files): mounted read-only when they aren't visible already
for f in "${path_args[@]}" "${mcp_args[@]}"; do
  [[ -n "$f" && "$f" != \{* ]] || continue
  [[ "$f" == /* ]] || f="$PWD/$f"
  [[ -e "$f" ]] || continue
  f="$(realpath "$f")"
  within "$f" "${rw_paths[@]}" /nix/store "$HOME/.claude" || mount_mode[$f]=ro
done

dir_mounts=()
for p in "${!mount_mode[@]}"; do
  dir_mounts+=(-v "$p:$p:${mount_mode[$p]}")
done
rw_dirs=()
for p in "${!mount_mode[@]}"; do
  [[ "${mount_mode[$p]}" == rw ]] && rw_dirs+=("$p")
done
log "mounts: project $project_mode, ${#rw_dirs[@]} more read-write, $(( ${#mount_mode[@]} - ${#rw_dirs[@]} )) read-only"

# Kept read-only on top of the writable mounts:
#  * the host-side Claude config (settings with its hooks, skills, agents),
#    or a session could plant a hook that runs unsandboxed on the host
#  * the .obsidian folder of any Obsidian vault mounted writable: community
#    plugins installed there would run in Obsidian on the host
protect_mounts=()
for p in "$HOME/.claude/settings.json" "$HOME/.claude/skills" "$HOME/.claude/agents" "$HOME/.claude/CLAUDE.md"; do
  [[ -e "$p" ]] && protect_mounts+=(-v "$p:$p:ro")
done
for d in "$project_root" "${rw_dirs[@]}"; do
  [[ -d "$d/.obsidian" && -z "${mount_mode[$d/.obsidian]:-}" ]] && protect_mounts+=(-v "$d/.obsidian:$d/.obsidian:ro")
done

# Host variables passed in: CLAUDE_SANDBOX_PASS_ENV, space-separated name
# globs (e.g. set by the system config for tools used inside the sandbox)
env_pass=()
read -ra pass_globs <<< "${CLAUDE_SANDBOX_PASS_ENV:-}"
if [[ ${#pass_globs[@]} -gt 0 ]]; then
  while IFS= read -r v; do
    for g in "${pass_globs[@]}"; do
      # shellcheck disable=SC2053 # a glob match on purpose
      if [[ "$v" == $g ]]; then
        env_pass+=(-e "$v=${!v}")
        break
      fi
    done
  done < <(compgen -e)
fi

# Only ask podman for a TTY when there is one, so headless runs (claude -p
# from a script) work too
tty_flags=(-i)
[[ -t 0 && -t 1 ]] && tty_flags=(-it)

# Git: the host's global config (a /nix/store file, with its per-remote
# identity includes), so commits made here carry the right author. Signing is
# off: the sandbox has no SSH agent, and no allowed-signers file to show
# signatures with; sign the commits on the host afterwards.
#
# Nested podman's storage gets an anonymous volume (removed with the
# container): on the container's own overlayfs root, overlay mounts in it
# (e.g. podman run --rootfs <dir>:O) fail, an overlay upperdir can't be on
# overlayfs.
log "starting claude in $pod_name-claude (pulls its image on first use)"
claude_started=1
systemd-run --user --scope --quiet --collect --slice=aisandbox.slice -- \
podman run --rm "${tty_flags[@]}" \
  --name "$pod_name-claude" \
  --pod "$pod_name" \
  "${name_labels[@]}" \
  --label claude-sandbox.role=claude \
  --privileged \
  --pull=missing \
  -v /nix/store:/nix/store:ro \
  -v /var/lib/containers \
  -v "$project_root:$project_root:$project_mode" \
  "${dir_mounts[@]}" \
  -w "$PWD" \
  -v "$asdf_data_dir:$asdf_data_dir:ro" \
  -v "$HOME/.claude:$HOME/.claude:rw" \
  -v "$HOME/.claude.json:$HOME/.claude.json:rw" \
  "${mounts[@]}" \
  "${protect_mounts[@]}" \
  "${dbus_mounts[@]}" \
  -e HOME="$HOME" \
  -e ASDF_DATA_DIR="$asdf_data_dir" \
  -e SSL_CERT_FILE="$CACERT_BUNDLE" \
  -e GIT_CONFIG_GLOBAL="$GIT_GLOBAL_CONFIG" \
  -e GIT_CONFIG_COUNT=3 \
  -e GIT_CONFIG_KEY_0=core.excludesFile \
  -e GIT_CONFIG_VALUE_0="$GIT_GLOBAL_IGNORE" \
  -e GIT_CONFIG_KEY_1=commit.gpgSign \
  -e GIT_CONFIG_VALUE_1=false \
  -e GIT_CONFIG_KEY_2=log.showSignature \
  -e GIT_CONFIG_VALUE_2=false \
  -e PATH="$asdf_data_dir/shims:$ASDF_VM_BIN:$NESTED_PODMAN_ENV_BIN:$DEV_TOOLS_BIN:$claude_out/bin:/usr/bin:/bin" \
  "${registry_env_flags[@]}" \
  "${dbus_env_flags[@]}" \
  "${env_pass[@]}" \
  "$CLAUDE_SANDBOX_IMAGE" \
  "$NESTED_PODMAN_SETUP" "$claude_out/bin/claude" "${mcp_flags[@]}" "$@"
code=$?
exit "$code"
