port_flags=()
dir_mounts=()
add_dir_flags=()
graphify_enabled=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ports)
      if [[ $# -lt 2 ]]; then
        echo "claude-sandbox: --ports requires a value" >&2
        exit 1
      fi
      IFS=',' read -ra ports <<< "$2"
      for p in "${ports[@]}"; do
        if ! [[ "$p" =~ ^[0-9]+$ ]]; then
          echo "claude-sandbox: --ports value must be a comma-separated list of numbers: $p" >&2
          exit 1
        fi
        port_flags+=(-p "$p:$p")
      done
      shift 2
      ;;
    --dirs)
      if [[ $# -lt 2 ]]; then
        echo "claude-sandbox: --dirs requires a value" >&2
        exit 1
      fi
      IFS=',' read -ra dirs <<< "$2"
      for d in "${dirs[@]}"; do
        if [[ ! -d "$d" ]]; then
          echo "claude-sandbox: --dirs entry is not a directory: $d" >&2
          exit 1
        fi
        abs_d="$(realpath "$d")"
        dir_mounts+=(-v "$abs_d:$abs_d:rw")
        add_dir_flags+=(--add-dir "$abs_d")
      done
      shift 2
      ;;
    --no-graphify)
      graphify_enabled=0
      shift
      ;;
    --)
      shift
      break
      ;;
    -h|--help)
      cat <<'EOF'
Usage: claude-sandbox [--ports <list>] [--dirs <list>] [--no-graphify]
                      [--] [claude args...]

Runs Claude Code inside a sandboxed, privileged rootless podman container
scoped to the current directory.

Options:
  --ports <list>  Comma-separated list of ports to publish from the
                  container to the same port on the host, e.g.
                  --ports 3000,5173
  --dirs <list>   Comma-separated list of additional host directories to
                  bind-mount read-write into the container (at the same
                  absolute path) and register with claude via --add-dir,
                  e.g. --dirs /home/user/other-project
  --no-graphify   Don't start the graphify sidecar (code graph MCP server,
                  kept in ./graphify-out) for this session.
  --              Stop parsing claude-sandbox's own flags; everything
                  after is passed straight through to the claude CLI
                  untouched.
  -h, --help      Show this help and exit.

If the current directory is a git checkout, it is fetched and fast-forwarded
to its upstream before launch; diverged branches or local changes in the
way are reported and left alone.

Anything else is passed straight through to the claude CLI.
EOF
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

project_root="$PWD"

# Fast-forward a git checkout to its upstream before anything else, so the
# graphify sidecar's startup build and watch begin on the updated tree
"$CLAUDE_GIT_UPDATE" "$project_root"
asdf_data_dir="$HOME/.asdf"

# Consolidated exit cleanup
cleanup() {
  [[ -n "${dbus_proxy_pid:-}" ]] && kill "$dbus_proxy_pid" 2>/dev/null || true
  [[ -n "${pod_name:-}" ]] && podman pod rm -f -t 5 "$pod_name" >/dev/null 2>&1 || true
  [[ -n "${tmp_dir:-}" && -d "$tmp_dir" ]] && rm -rf "$tmp_dir"
  [[ -n "${dbus_proxy_dir:-}" && -d "$dbus_proxy_dir" ]] && rm -rf "$dbus_proxy_dir"
}
trap cleanup EXIT

export NIXPKGS_ALLOW_UNFREE=1
claude_out="$(NIXPKGS_ALLOW_UNFREE=1 nix build \
    --impure \
    --no-link \
    --print-out-paths \
    'nixpkgs#claude-code'
)"

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
    sandbox-proxy start
  fi
fi

# MCP servers (e.g. Jira/Bitbucket via Atlassian Rovo), reached through
# mcp-proxy on the sandbox-mcp network, which injects the auth headers
proxy_mcp_config=""
if [[ "$proxy_mcp" == 1 ]]; then
  network_flags+=(--network sandbox-mcp)
  proxy_mcp_config="$(sandbox-proxy sandbox-mcp-config)"
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
# real bus and, and only allows calls to to org.freedesktop.Notifications. The
# filtered socket is then bind-mounted in, allowing for safe use of dbus for
# notifications in a the sandboxed environment
dbus_mounts=()
dbus_env_flags=()
real_bus_address="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
if [[ "$real_bus_address" == unix:path=* || "$real_bus_address" == unix:abstract=* ]]; then
  dbus_proxy_dir="$(mktemp -d)"
  dbus_proxy_socket="$dbus_proxy_dir/notify-bus"

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
    echo "claude-sandbox: DBus notification proxy didn't come up, sandbox notifications will be unavailable" >&2
    kill "$dbus_proxy_pid" 2>/dev/null || true
    dbus_proxy_pid=""
  fi
fi

# Claude and the graphify sidecar share one pod, and with it a network
# namespace, so the sidecar's MCP endpoint is reachable on Claude's
# localhost without being published anywhere else. Ports/networks that used
# to sit on the claude container live on the pod now.
#
# Everything is named after the git repo (origin's URL, else the first
# remote) plus the checkout folder, e.g. claude-sandbox-ships-service-db4005a08
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
if [[ -n "$repo_name" && "$repo_name" != "$folder_name" ]]; then
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
pod_name=""
n=1
while [[ -z "$pod_name" ]]; do
  candidate="$name_base"
  [[ "$n" -gt 1 ]] && candidate="$name_base-$n"
  n=$((n + 1))
  podman pod exists "$candidate" && continue
  if create_err="$(podman pod create --name "$candidate" --infra-name "$candidate-infra" \
      "${name_labels[@]}" \
      "${port_flags[@]}" \
      "${network_flags[@]}" 2>&1 >/dev/null)"; then
    pod_name="$candidate"
  elif ! grep -qi "already" <<< "$create_err"; then
    # Not a name clash but a real failure (e.g. a --ports conflict)
    echo "claude-sandbox: couldn't create pod $candidate: $create_err" >&2
    exit 1
  fi
done
echo "claude-sandbox: pod $pod_name" >&2

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

if [[ "$graphify_enabled" == 1 ]]; then
  if ! has_graphify_sources; then
    echo "claude-sandbox: no source files graphify can parse here, skipping the graphify sidecar" >&2
    graphify_enabled=0
  fi
fi

if [[ "$graphify_enabled" == 1 ]]; then
  graphify_port=47100
  graphify_key="$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')"
  systemd-run --user --scope --quiet --collect --slice=ai-sandbox.slice -- \
  podman run -d \
    --name "$pod_name-graphify" \
    --pod "$pod_name" \
    "${name_labels[@]}" \
    --label claude-sandbox.role=graphify \
    --pull=missing \
    -v claude-sandbox-graphify:/opt/graphify \
    -v "$GRAPHIFY_SIDECAR:/sidecar.sh:ro" \
    -v "$project_root:$project_root:rw" \
    -e GRAPHIFY_VERSION="$GRAPHIFY_VERSION" \
    -e GRAPHIFY_PORT="$graphify_port" \
    -e GRAPHIFY_API_KEY="$graphify_key" \
    -e PROJECT_ROOT="$project_root" \
    -e GRAPHIFY_QUERY_LOG_DISABLE=1 \
    docker.io/library/python:3.12-slim \
    sh /sidecar.sh >/dev/null

  # First run pip-installs graphify and the first graph build of a large
  # repo can take a while, so wait for the MCP endpoint before starting Claude
  echo "claude-sandbox: starting the graphify sidecar; building the code graph can take a few minutes on a large or first-time project (--no-graphify skips it, podman logs -f $pod_name-graphify follows it)..." >&2
  graphify_ready=0
  for _ in $(seq 1 300); do
    if [[ "$(podman inspect -f '{{.State.Running}}' "$pod_name-graphify" 2>/dev/null)" != true ]]; then
      break
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
    graphify_mcp_config="{\"mcpServers\":{\"graphify\":{\"type\":\"http\",\"url\":\"http://127.0.0.1:$graphify_port/mcp\",\"headers\":{\"Authorization\":\"Bearer $graphify_key\"}}}}"
  else
    echo "claude-sandbox: graphify sidecar didn't come up, continuing without it:" >&2
    podman logs --tail 20 "$pod_name-graphify" >&2 2>&1 || true
    podman rm -f -t 0 "$pod_name-graphify" >/dev/null 2>&1 || true
  fi
fi

# All MCP servers go into one file passed as --mcp-config=<file>: the flag
# is variadic, so a separate value would swallow a following positional
# prompt as another config file
mcp_flags=()
if [[ -n "$proxy_mcp_config$graphify_mcp_config" ]]; then
  printf '%s\n' "$proxy_mcp_config" "$graphify_mcp_config" \
    | jq -s '{mcpServers: (map(select(. != null) | .mcpServers) | add)}' > "$tmp_dir/mcp.json"
  mounts+=(-v "$tmp_dir/mcp.json:$tmp_dir/mcp.json:ro")
  mcp_flags+=("--mcp-config=$tmp_dir/mcp.json")
fi

systemd-run --user --scope --quiet --collect --slice=ai-sandbox.slice -- \
podman run --rm -it \
  --name "$pod_name-claude" \
  --pod "$pod_name" \
  "${name_labels[@]}" \
  --label claude-sandbox.role=claude \
  --privileged \
  --pull=missing \
  -v /nix/store:/nix/store:ro \
  "${dir_mounts[@]}" \
  -v "$project_root:$project_root:rw" \
  -w "$PWD" \
  -v "$asdf_data_dir:$asdf_data_dir:ro" \
  -v "$HOME/.claude:$HOME/.claude:rw" \
  -v "$HOME/.claude.json:$HOME/.claude.json:rw" \
  "${mounts[@]}" \
  "${dbus_mounts[@]}" \
  -e HOME="$HOME" \
  -e ASDF_DATA_DIR="$asdf_data_dir" \
  -e SSL_CERT_FILE="$CACERT_BUNDLE" \
  -e GIT_CONFIG_COUNT=1 \
  -e GIT_CONFIG_KEY_0=core.excludesFile \
  -e GIT_CONFIG_VALUE_0="$GIT_GLOBAL_IGNORE" \
  -e PATH="$asdf_data_dir/shims:$ASDF_VM_BIN:$NESTED_PODMAN_ENV_BIN:$DEV_TOOLS_BIN:$claude_out/bin:/usr/bin:/bin" \
  "${registry_env_flags[@]}" \
  "${dbus_env_flags[@]}" \
  docker.io/library/debian:stable-slim \
  "$NESTED_PODMAN_SETUP" "$claude_out/bin/claude" "${add_dir_flags[@]}" "${mcp_flags[@]}" "$@"
code=$?
exit "$code"
