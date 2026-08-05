# TODO: generalize to work with multiple repositories/credential sets
# TODO: wrap all 3rd party tools so private repo credentials are never stored
#       in plaintext

NETWORK_NAME="sandbox-registry"
# Explicit subnet + a fixed IP for registry-proxy (Caddy) below, so sandbox
# wrappers can --add-host the real Artifactory hostname straight to a known,
# stable address instead of a network-wide alias
NETWORK_SUBNET="172.30.99.0/24"
REGISTRY_PROXY_IP="172.30.99.2"
CACHE_DIR="$HOME/.local/share/registry-cache"
NPM_PROXY_STORAGE_VOLUME="npm-proxy-storage"
NPM_PROXY_CONFIG_DIR="${XDG_RUNTIME_DIR:-/tmp}/registry-proxy"

touch "$HOME/.custom"
usage() {
  cat >&2 <<'USAGE'
Usage:
  registry-proxy host-login <host> --npm-repo <repo> --go-repo <repo> --docker-repo <repo>
  registry-proxy start
  registry-proxy stop
  registry-proxy status
  registry-proxy configured   (silent; exit 0/1, used by the sandbox wrappers)
  registry-proxy sandbox-npmrc
  registry-proxy sandbox-goproxy
  registry-proxy sandbox-docker-prefix
  registry-proxy sandbox-extra-host
USAGE
}

normalize_host() {
  echo "${1%:443}"
}

ensure_op_signed_in() {
  if op whoami >/dev/null 2>&1; then
    return 0
  fi
  echo "registry-proxy: not signed in to 1Password, running 'op signin'..." >&2
  local signin_exports
  if ! signin_exports="$(op signin 2>&1)"; then
    echo "registry-proxy: op signin failed: $signin_exports" >&2
    exit 1
  fi
}

# Resolves the shared Artifactory credential from a 1Password item titled
# exactly the given hostname. Sets ARTIFACTORY_USER/ARTIFACTORY_PASS.
op_get_creds() {
  local host="$1" json
  if ! command -v op >/dev/null 2>&1; then
    echo "registry-proxy: 1Password CLI (op) not found" >&2
    exit 1
  fi
  ensure_op_signed_in
  if ! json="$(op item get "$host" --fields label=username,label=password --reveal --format json 2>&1)"; then
    echo "registry-proxy: could not read 1Password item '$host': $json" >&2
    exit 1
  fi
  ARTIFACTORY_USER="$(jq -r '.[] | select(.label=="username") | .value' <<< "$json")"
  ARTIFACTORY_PASS="$(jq -r '.[] | select(.label=="password") | .value' <<< "$json")"
  if [ -z "$ARTIFACTORY_USER" ] || [ -z "$ARTIFACTORY_PASS" ]; then
    echo "registry-proxy: 1Password item '$host' is missing a username or password field" >&2
    exit 1
  fi
}

# Discovers the configured Artifactory host + npm/go/docker paths by reading
# back the native config host-login already wrote. Sets ARTIFACTORY_HOST,
# NPM_PATH, GO_PATH, and DOCKER_REPO.
discover_config() {
  ARTIFACTORY_HOST="" NPM_PATH="" GO_PATH="" DOCKER_REPO=""

  if [ -f "$HOME/.npmrc" ]; then
    local reg_line reg_url no_scheme
    reg_line="$(grep -m1 '^registry=' "$HOME/.npmrc" || true)"
    if [ -n "$reg_line" ]; then
      reg_url="${reg_line#registry=}"
      no_scheme="${reg_url#https://}"
      no_scheme="${no_scheme#http://}"
      ARTIFACTORY_HOST="$(normalize_host "${no_scheme%%/*}")"
      NPM_PATH="/${no_scheme#*/}"
    fi
  fi

  if [ -f "$HOME/.custom" ]; then
    local goproxy_line goproxy no_scheme no_userinfo
    goproxy_line="$(grep -m1 '^export GOPROXY=' "$HOME/.custom" || true)"
    if [ -n "$goproxy_line" ]; then
      goproxy="${goproxy_line#export GOPROXY=}"
      no_scheme="${goproxy#https://}"
      no_scheme="${no_scheme#http://}"

      # Strip an embedded user:pass@ userinfo prefix, if present
      no_userinfo="${no_scheme#*@}"
      if [ -z "$ARTIFACTORY_HOST" ]; then
        ARTIFACTORY_HOST="$(normalize_host "${no_userinfo%%/*}")"
      fi
      GO_PATH="/${no_userinfo#*/}"
    fi

    local docker_repo_line
    docker_repo_line="$(grep -m1 '^export ARTIFACTORY_DOCKER_REPO=' "$HOME/.custom" || true)"
    if [ -n "$docker_repo_line" ]; then
      DOCKER_REPO="${docker_repo_line#export ARTIFACTORY_DOCKER_REPO=}"
    fi
  fi
}

cmd_host_login() {
  local host="${1:-}"
  if [ -z "$host" ]; then
    echo "registry-proxy: host-login requires a hostname" >&2
    usage
    exit 1
  fi
  host="$(normalize_host "$host")"
  shift

  local npm_repo="" go_repo="" docker_repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --npm-repo) npm_repo="$2"; shift 2 ;;
      --go-repo) go_repo="$2"; shift 2 ;;
      --docker-repo) docker_repo="$2"; shift 2 ;;
      *) echo "registry-proxy: unknown host-login option: $1" >&2; exit 1 ;;
    esac
  done

  op_get_creds "$host"

  echo "$ARTIFACTORY_PASS" | podman login "$host" -u "$ARTIFACTORY_USER" --password-stdin
  echo "registry-proxy: podman login succeeded for $host"

  if [ -n "$npm_repo" ]; then
    local npm_path="artifactory/api/npm/$npm_repo/" auth_b64 npmrc
    auth_b64="$(printf '%s:%s' "$ARTIFACTORY_USER" "$ARTIFACTORY_PASS" | base64 -w0)"
    npmrc="$HOME/.npmrc"
    touch "$npmrc"
    grep -v '^registry=' "$npmrc" | grep -vF "//$host/$npm_path" > "$npmrc.tmp" || true
    mv "$npmrc.tmp" "$npmrc"
    {
      echo "registry=https://$host/$npm_path"
      echo "//$host/$npm_path:_auth=$auth_b64"
    } >> "$npmrc"
    echo "registry-proxy: updated $npmrc for $host/$npm_path"
  fi

  if [ -n "$go_repo" ]; then
    # GOPROXY carries its own Basic Auth credentials (https://user:pass@host/path)
    local go_path="artifactory/api/go/$go_repo" custom enc_user enc_pass goproxy_url
    local existing_goproxy fallback
    enc_user="$(jq -rn --arg s "$ARTIFACTORY_USER" '$s|@uri')"
    enc_pass="$(jq -rn --arg s "$ARTIFACTORY_PASS" '$s|@uri')"
    goproxy_url="https://$enc_user:$enc_pass@$host/$go_path"
    custom="$HOME/.custom"

    # Keep any existing goproxy fallbacks, if none exist, then use default fallbacks
    existing_goproxy="$(grep -m1 '^export GOPROXY=' "$custom" 2>/dev/null || true)"
    existing_goproxy="${existing_goproxy#export GOPROXY=}"

    case "$existing_goproxy" in
      \"*\") existing_goproxy="${existing_goproxy#\"}"; existing_goproxy="${existing_goproxy%\"}" ;;
      \'*\') existing_goproxy="${existing_goproxy#\'}"; existing_goproxy="${existing_goproxy%\'}" ;;
    esac
    fallback="${existing_goproxy#*,}"
    if [ -z "$existing_goproxy" ] || [ "$fallback" = "$existing_goproxy" ]; then
      fallback="https://proxy.golang.org,direct"
    fi
    goproxy_url="$goproxy_url,$fallback"

    grep -v '^export GOPROXY=' "$custom" > "$custom.tmp" 2>/dev/null || true
    mv "$custom.tmp" "$custom"
    echo "export GOPROXY=$goproxy_url" >> "$custom"
    chmod 600 "$custom"
    echo "registry-proxy: updated $custom (GOPROXY) for $host/$go_path"
  fi

  if [ -n "$docker_repo" ]; then
    local custom
    custom="$HOME/.custom"
    grep -v '^export ARTIFACTORY_DOCKER_REPO=' "$custom" > "$custom.tmp" || true
    mv "$custom.tmp" "$custom"
    echo "export ARTIFACTORY_DOCKER_REPO=$docker_repo" >> "$custom"
    echo "registry-proxy: updated $custom (ARTIFACTORY_DOCKER_REPO) for $host/$docker_repo"
  fi
}

cmd_start() {
  discover_config
  if [ -z "$ARTIFACTORY_HOST" ]; then
    echo "registry-proxy: no registry configured -- run 'registry-proxy host-login <host> --npm-repo <repo> --go-repo <repo>' first" >&2
    exit 1
  fi

  op_get_creds "$ARTIFACTORY_HOST"
  local auth_b64
  auth_b64="$(printf '%s:%s' "$ARTIFACTORY_USER" "$ARTIFACTORY_PASS" | base64 -w0)"

  # Caddy's host-matched HTTPS block, strips the trailing-slash
  # prefix before forwarding to Verdaccio
  local npm_strip_prefix="${NPM_PATH%/}"
  if [ -z "$npm_strip_prefix" ]; then
    npm_strip_prefix="/__no_npm_repo_configured__"
  fi

  if podman network exists "$NETWORK_NAME"; then
    local existing_subnet
    existing_subnet="$(podman network inspect "$NETWORK_NAME" --format '{{(index .Subnets 0).Subnet}}' 2>/dev/null || true)"
    if [ "$existing_subnet" != "$NETWORK_SUBNET" ]; then
      podman rm -f registry-proxy registry-cache npm-proxy >/dev/null 2>&1 || true
      podman network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
    fi
  fi
  podman network exists "$NETWORK_NAME" || podman network create --subnet "$NETWORK_SUBNET" "$NETWORK_NAME"
  mkdir -p "$CACHE_DIR"

  podman run -d --replace \
    --name registry-proxy \
    --network "$NETWORK_NAME" \
    --network-alias registry-proxy \
    --ip "$REGISTRY_PROXY_IP" \
    -e ARTIFACTORY_HOST="$ARTIFACTORY_HOST" \
    -e ARTIFACTORY_BASIC_AUTH="$auth_b64" \
    -e NPM_STRIP_PREFIX="$npm_strip_prefix" \
    -v "$REGISTRY_PROXY_CADDYFILE:/etc/caddy/Caddyfile:ro" \
    docker.io/library/caddy:latest

  podman run -d --replace \
    --name registry-cache \
    --network "$NETWORK_NAME" --network-alias registry-cache \
    -e REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=/var/lib/registry \
    -e REGISTRY_PROXY_REMOTEURL="https://$ARTIFACTORY_HOST" \
    -e REGISTRY_PROXY_USERNAME="$ARTIFACTORY_USER" \
    -e REGISTRY_PROXY_PASSWORD="$ARTIFACTORY_PASS" \
    -v "$CACHE_DIR:/var/lib/registry" \
    docker.io/library/registry:2

  if [ -n "$NPM_PATH" ]; then
    mkdir -p "$NPM_PROXY_CONFIG_DIR"
    cat > "$NPM_PROXY_CONFIG_DIR/verdaccio-config.yaml" <<EOF
storage: /verdaccio/storage
listen: 0.0.0.0:4873
uplinks:
  artifactory:
    url: https://$ARTIFACTORY_HOST$NPM_PATH
    auth:
      type: bearer
      token_env: ARTIFACTORY_TOKEN
packages:
  '**':
    access: \$all
    publish: \$authenticated
    proxy: artifactory
EOF

    podman volume create "$NPM_PROXY_STORAGE_VOLUME" >/dev/null 2>&1 || true

    podman run -d --replace \
      --name npm-proxy \
      --network "$NETWORK_NAME" --network-alias npm-proxy \
      -e ARTIFACTORY_TOKEN="$ARTIFACTORY_PASS" \
      -e VERDACCIO_PUBLIC_URL="https://$ARTIFACTORY_HOST$NPM_PATH" \
      -v "$NPM_PROXY_CONFIG_DIR/verdaccio-config.yaml:/verdaccio/conf/config.yaml:ro" \
      -v "$NPM_PROXY_STORAGE_VOLUME:/verdaccio/storage" \
      docker.io/verdaccio/verdaccio:5
  fi

  local path_shown="${NPM_PATH:-${GO_PATH:-unset}}"
  echo "registry-proxy: started for $ARTIFACTORY_HOST (npm/go path: $path_shown)"
}

cmd_stop() {
  podman rm -f registry-proxy registry-cache npm-proxy 2>/dev/null || true
}

cmd_status() {
  podman ps --filter "network=$NETWORK_NAME"
}

# exit 0 if a registry is configured, 1 otherwise
cmd_configured() {
  discover_config
  [ -n "$ARTIFACTORY_HOST" ]
}

# Prints the .npmrc file that should be mounted in the sandboxes to point to the registries
cmd_sandbox_npmrc() {
  discover_config
  if [ -z "$NPM_PATH" ]; then
    echo "registry-proxy: no npm registry configured (run host-login --npm-repo first)" >&2
    exit 1
  fi

  # Disable ssl as caddy is running with a self signed cert for convienience
  echo "strict-ssl=false"
  echo "registry=https://$ARTIFACTORY_HOST$NPM_PATH"
}

# Prints the exact "--add-host" value ("host:ip") sandboxes should add to redirect
# requests to the proxy
cmd_sandbox_extra_host() {
  discover_config
  if [ -z "$ARTIFACTORY_HOST" ]; then
    echo "registry-proxy: no registry configured (run host-login first)" >&2
    exit 1
  fi
  echo "$ARTIFACTORY_HOST:$REGISTRY_PROXY_IP"
}

cmd_sandbox_goproxy() {
  discover_config
  if [ -z "$GO_PATH" ]; then
    echo "registry-proxy: no go registry configured (run host-login --go-repo first)" >&2
    exit 1
  fi
  echo "http://registry-proxy:7080$GO_PATH"
}

# Prints the full mirror prefix to scope the docker registries.conf mirror to
cmd_sandbox_docker_prefix() {
  discover_config
  if [ -z "$ARTIFACTORY_HOST" ]; then
    echo "registry-proxy: no registry configured (run host-login first)" >&2
    exit 1
  fi
  if [ -n "$DOCKER_REPO" ]; then
    echo "$ARTIFACTORY_HOST/$DOCKER_REPO"
  else
    echo "$ARTIFACTORY_HOST"
  fi
}

case "${1:-}" in
  host-login) shift; cmd_host_login "$@" ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  configured) cmd_configured ;;
  sandbox-npmrc) cmd_sandbox_npmrc ;;
  sandbox-goproxy) cmd_sandbox_goproxy ;;
  sandbox-docker-prefix) cmd_sandbox_docker_prefix ;;
  sandbox-extra-host) cmd_sandbox_extra_host ;;
  *) usage; exit 1 ;;
esac
