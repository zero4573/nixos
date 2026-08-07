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
  trap 'rm -rf "$tmp_dir"' EXIT

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
  -e HOME="$HOME" \
  -e ASDF_DATA_DIR="$asdf_data_dir" \
  -e SSL_CERT_FILE="$CACERT_BUNDLE" \
  -e PATH="$asdf_data_dir/shims:$ASDF_VM_BIN:$NESTED_PODMAN_ENV_BIN:$claude_out/bin:/usr/bin:/bin" \
  "${registry_env_flags[@]}" \
  docker.io/library/debian:stable-slim \
  "$NESTED_PODMAN_SETUP" "$claude_out/bin/claude" "${add_dir_flags[@]}" "$@"
code=$?
exit "$code"
