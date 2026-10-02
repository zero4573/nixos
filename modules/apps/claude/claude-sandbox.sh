port_flags=()
dir_mounts=()
add_dir_flags=()
graphify_enabled=1
vault_arg=""
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
    --vault)
      if [[ $# -lt 2 ]]; then
        echo "claude-sandbox: --vault requires a value" >&2
        exit 1
      fi
      vault_arg="$2"
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
Usage: claude-sandbox [--ports <list>] [--dirs <list>] [--vault <name>]
                      [--no-graphify] [--] [claude args...]

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
  --vault <name>  Obsidian vault under ~/Documents/Obsidian that the
                  graphify sidecar exports this project's graph into
                  (<vault>/graphify/<repo>). Remembered per project;
                  `none` disables the export. Without this flag the saved
                  choice is used, or you're prompted on first run.
  --no-graphify   Don't start the graphify sidecar for this session.
  --              Stop parsing claude-sandbox's own flags; everything
                  after is passed straight through to the claude CLI
                  untouched.
  -h, --help      Show this help and exit.

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
if command -v registry-proxy >/dev/null 2>&1 && registry-proxy configured; then
  registry-proxy start

  network_flags+=(--network sandbox-registry)

  if npmrc_line="$(registry-proxy sandbox-npmrc 2>/dev/null)"; then
    echo "$npmrc_line" > "$tmp_dir/.npmrc"
    mounts+=(-v "$tmp_dir/.npmrc:$HOME/.npmrc:ro")
  fi

  if goproxy_url="$(registry-proxy sandbox-goproxy 2>/dev/null)"; then
    registry_env_flags+=(-e "GOPROXY=$goproxy_url")
  fi

  if docker_prefix="$(registry-proxy sandbox-docker-prefix 2>/dev/null)"; then
    registry_env_flags+=(-e "REGISTRY_MIRROR_PREFIX=$docker_prefix")
  fi

  if extra_host="$(registry-proxy sandbox-extra-host 2>/dev/null)"; then
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
pod_name="claude-sandbox-$$"
podman pod create --name "$pod_name" \
  "${port_flags[@]}" \
  "${network_flags[@]}" >/dev/null

# graphify sidecar: builds a code graph of the project (local tree-sitter,
# no LLM), keeps it current, serves it to Claude as an MCP server, and
# exports it as Obsidian notes into <vault>/graphify/<repo>. The vault
# choice is stored per project on the host (outside every container mount),
# so the sandboxed Claude can't redirect it.
mcp_flags=()
if [[ "$graphify_enabled" == 1 ]]; then
  obsidian_root="$HOME/Documents/Obsidian"
  state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/claude-sandbox"
  vault_file="$state_dir/graphify-vaults.tsv"
  mkdir -p "$state_dir"
  touch "$vault_file"

  valid_vault() {
    [[ "$1" == none ]] || { [[ "$1" != */* && "$1" != .* && -d "$obsidian_root/$1" ]]; }
  }

  save_vault() {
    awk -F'\t' -v p="$project_root" '$1 != p' "$vault_file" > "$vault_file.tmp"
    printf '%s\t%s\n' "$project_root" "$1" >> "$vault_file.tmp"
    mv "$vault_file.tmp" "$vault_file"
  }

  vault=""
  if [[ -n "$vault_arg" ]]; then
    if ! valid_vault "$vault_arg"; then
      echo "claude-sandbox: --vault must be \`none\` or a vault directory under $obsidian_root: $vault_arg" >&2
      exit 1
    fi
    vault="$vault_arg"
    save_vault "$vault"
  else
    saved="$(awk -F'\t' -v p="$project_root" '$1 == p { v = $2 } END { print v }' "$vault_file")"
    if [[ -n "$saved" ]] && valid_vault "$saved"; then
      vault="$saved"
    elif [[ -t 0 ]]; then
      vaults=()
      for d in "$obsidian_root"/*/; do
        [[ -d "$d" ]] && vaults+=("$(basename "$d")")
      done
      echo "claude-sandbox: pick an Obsidian vault for this project's graphify export:" >&2
      PS3="vault> "
      select choice in "${vaults[@]}" none; do
        [[ -n "$choice" ]] && break
      done
      vault="${choice:-none}"
      save_vault "$vault"
    else
      vault="none"
    fi
  fi

  # Export folder is named after the git repo (origin's URL, else the first
  # remote), not the checkout directory
  vault_mounts=()
  vault_env_flags=()
  if [[ "$vault" != none ]]; then
    remote_url="$(git -C "$project_root" remote get-url origin 2>/dev/null \
      || git -C "$project_root" remote get-url "$(git -C "$project_root" remote 2>/dev/null | head -n1)" 2>/dev/null \
      || true)"
    repo_name="${remote_url%/}"
    repo_name="${repo_name%.git}"
    repo_name="${repo_name##*[/:]}"
    if [[ "$repo_name" =~ ^[A-Za-z0-9._-]+$ && "$repo_name" != .* ]]; then
      vault_export_dir="$obsidian_root/$vault/graphify/$repo_name"
      mkdir -p "$vault_export_dir"
      vault_mounts+=(-v "$vault_export_dir:$vault_export_dir:rw")
      vault_env_flags+=(-e "VAULT_EXPORT_DIR=$vault_export_dir")
      echo "claude-sandbox: graphify exporting to $vault_export_dir" >&2
    else
      echo "claude-sandbox: no git remote to name the graphify export after, skipping the Obsidian export" >&2
    fi
  fi

  graphify_port=47100
  graphify_key="$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')"
  systemd-run --user --scope --quiet --collect --slice=ai-sandbox.slice -- \
  podman run -d \
    --name "$pod_name-graphify" \
    --pod "$pod_name" \
    --pull=missing \
    -v claude-sandbox-graphify:/opt/graphify \
    -v "$GRAPHIFY_SIDECAR:/sidecar.sh:ro" \
    -v "$project_root:$project_root:rw" \
    "${vault_mounts[@]}" \
    -e GRAPHIFY_VERSION="$GRAPHIFY_VERSION" \
    -e GRAPHIFY_PORT="$graphify_port" \
    -e GRAPHIFY_API_KEY="$graphify_key" \
    -e PROJECT_ROOT="$project_root" \
    -e GRAPHIFY_QUERY_LOG_DISABLE=1 \
    "${vault_env_flags[@]}" \
    docker.io/library/python:3.12-slim \
    sh /sidecar.sh >/dev/null

  # First run pip-installs graphify and the first graph build of a large
  # repo can take a while, so wait for the MCP endpoint before starting Claude
  echo "claude-sandbox: waiting for graphify sidecar (podman logs -f $pod_name-graphify)..." >&2
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
    cat > "$tmp_dir/graphify-mcp.json" <<JSON
{"mcpServers":{"graphify":{"type":"http","url":"http://127.0.0.1:$graphify_port/mcp","headers":{"Authorization":"Bearer $graphify_key"}}}}
JSON
    mounts+=(-v "$tmp_dir/graphify-mcp.json:$tmp_dir/graphify-mcp.json:ro")
    mcp_flags+=(--mcp-config "$tmp_dir/graphify-mcp.json")
  else
    echo "claude-sandbox: graphify sidecar didn't come up, continuing without it:" >&2
    podman logs --tail 20 "$pod_name-graphify" >&2 2>&1 || true
    podman rm -f -t 0 "$pod_name-graphify" >/dev/null 2>&1 || true
  fi
fi

systemd-run --user --scope --quiet --collect --slice=ai-sandbox.slice -- \
podman run --rm -it \
  --pod "$pod_name" \
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
  -e PATH="$asdf_data_dir/shims:$ASDF_VM_BIN:$NESTED_PODMAN_ENV_BIN:$DEV_TOOLS_BIN:$claude_out/bin:/usr/bin:/bin" \
  "${registry_env_flags[@]}" \
  "${dbus_env_flags[@]}" \
  docker.io/library/debian:stable-slim \
  "$NESTED_PODMAN_SETUP" "$claude_out/bin/claude" "${add_dir_flags[@]}" "${mcp_flags[@]}" "$@"
code=$?
exit "$code"
