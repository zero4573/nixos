port_flags=()
dir_mounts=()
add_dir_flags=()
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
    --)
      shift
      break
      ;;
    -h|--help)
      cat <<'EOF'
Usage: claude-sandbox [--ports <list>] [--dirs <list>] [--] [claude args...]

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
tmp_dir=""
if command -v registry-proxy >/dev/null 2>&1 && registry-proxy configured; then
  registry-proxy start

  tmp_dir="$(mktemp -d)"

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

systemd-run --user --scope --quiet --collect --slice=ai-sandbox.slice -- \
podman run --rm -it \
  --privileged \
  --pull=missing \
  "${port_flags[@]}" \
  "${network_flags[@]}" \
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
  -e PATH="$asdf_data_dir/shims:$ASDF_VM_BIN:$NESTED_PODMAN_ENV_BIN:$claude_out/bin:/usr/bin:/bin" \
  "${registry_env_flags[@]}" \
  "${dbus_env_flags[@]}" \
  docker.io/library/debian:stable-slim \
  "$NESTED_PODMAN_SETUP" "$claude_out/bin/claude" "${add_dir_flags[@]}" "$@"
code=$?
exit "$code"
