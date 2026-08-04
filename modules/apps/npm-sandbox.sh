project_root="$PWD"

if ! current_line="$(asdf current nodejs --no-header 2>&1)"; then
  echo "npm-sandbox: could not resolve a nodejs version via asdf for $project_root" >&2
  echo "$current_line" >&2
  exit 1
fi
node_version="$(awk '{print $2}' <<< "$current_line")"

mounts=(-v "$project_root:$project_root:rw")
network_flags=()
tmp_dir=""
if command -v registry-proxy >/dev/null 2>&1 && registry-proxy configured; then
  registry-proxy start

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT
  registry-proxy sandbox-npmrc > "$tmp_dir/.npmrc"

  network_flags+=(--network sandbox-registry)
  mounts+=(-v "$tmp_dir/.npmrc:$HOME/.npmrc:ro")

  if extra_host="$(registry-proxy sandbox-extra-host 2>/dev/null)"; then
    network_flags+=(--add-host "$extra_host")
  fi
fi

podman run --rm \
  --pull=missing \
  "${network_flags[@]}" \
  "${mounts[@]}" \
  -w "$project_root" \
  -e HOME="$HOME" \
  "docker.io/library/node:$node_version" \
  npm "$@"
code=$?
exit "$code"
