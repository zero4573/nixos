# TODO: generalize to work with multiple repositories/credential sets
# TODO: wrap all 3rd party tools so private repo credentials are never stored
#       in plaintext

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/sandbox-proxy"

# --- package registry service ---
NETWORK_NAME="sandbox-registry"
# Explicit subnet + a fixed IP for registry-proxy (Caddy) below, so sandbox
# wrappers can --add-host the real Artifactory hostname straight to a known,
# stable address instead of a network-wide alias
NETWORK_SUBNET="172.30.99.0/24"
REGISTRY_PROXY_IP="172.30.99.2"
CACHE_DIR="$HOME/.local/share/registry-cache"
NPM_PROXY_STORAGE_VOLUME="npm-proxy-storage"
NPM_PROXY_CONFIG_DIR="$RUNTIME_DIR"

# --- MCP service ---
# Separate network from the registry one: only claude-sandbox joins it, so
# npm-sandbox (untrusted install scripts) can never reach a proxy that acts
# as you against e.g. Jira/Bitbucket
MCP_NETWORK_NAME="sandbox-mcp"
MCP_NETWORK_SUBNET="172.30.98.0/24"
MCP_PROXY_PORT=8080
# The MCP routes are also published on the host loopback, for host tools that
# talk to the servers without a model (e.g. a ticket sync). Any local process
# can use them, with the (read-only) credentials the proxy injects.
MCP_HOST_PORT="${SANDBOX_PROXY_MCP_HOST_PORT:-47180}"
MCP_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/sandbox-proxy/mcp-servers.json"
# Standard MCP config of the host URLs, rewritten whenever the server list
# changes or the proxy starts
MCP_HOST_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/sandbox-proxy/mcp-host.json"

usage() {
  cat >&2 <<'USAGE'
Usage:
  sandbox-proxy host-login <host> --npm-repo <repo> --go-repo <repo> --docker-repo <repo>
  sandbox-proxy start [registry|mcp]   (default: every configured service;
                                        reuses proxies already running with
                                        the same config)
  sandbox-proxy restart [registry|mcp] (recreate them, re-reading 1Password,
                                        e.g. after rotating a credential)
  sandbox-proxy stop
  sandbox-proxy prune [--days N]   (drop npm-cache tarballs unused for N days, default 60)
  sandbox-proxy status
  sandbox-proxy configured   (silent; exit 0/1, used by the sandbox wrappers)
  sandbox-proxy sandbox-npmrc
  sandbox-proxy sandbox-goproxy
  sandbox-proxy sandbox-docker-prefix
  sandbox-proxy sandbox-extra-host
  sandbox-proxy mcp add <name> --url <url> --op-item <1password item> [--auth basic|bearer]
  sandbox-proxy mcp remove <name>
  sandbox-proxy mcp list
  sandbox-proxy mcp-configured   (silent; exit 0/1, used by claude-sandbox)
  sandbox-proxy sandbox-mcp-config
  sandbox-proxy host-mcp-config   (the same servers at 127.0.0.1:$MCP_HOST_PORT;
                                   also kept in ~/.config/sandbox-proxy/mcp-host.json)
USAGE
}

normalize_host() {
  echo "${1%:443}"
}

# Images, pinned to an exact version and the digest of its multi-arch index
# (see UPDATES.md to bump). They're part of the containers' fingerprint
# (below, through this script), so a bump recreates them on the next start.
CADDY_IMAGE="docker.io/library/caddy:2.11.6@sha256:907efba736324e43f891ccb9d760fe5abe545e313419b3d18d63d4ec670dad8d"
REGISTRY_IMAGE="docker.io/library/registry:2.8.3@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373"
VERDACCIO_IMAGE="docker.io/verdaccio/verdaccio:5.33.0@sha256:9d622d256378c6e7ae09f384774ee2f0f8ac67a66c066db55921a0b7218abc4c"
DEBIAN_IMAGE="docker.io/library/debian:trixie-20260918-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a"

# --- reuse of running proxies ---
# Every claude-sandbox launch runs `sandbox-proxy start`, and several sessions
# share these containers. `start` therefore leaves a service alone when its
# containers are running with the same config: recreating them would cut off
# the other sessions' in-flight requests, and re-read 1Password every time.
# Each container carries a fingerprint label of everything it was built from
# except the secrets (this script itself, the non-secret config, the
# Caddyfile template), so it's recreated after a config or script change.
# `restart` forces a recreate, e.g. after rotating a credential in 1Password.
FINGERPRINT_LABEL="sandbox-proxy.fingerprint"
FORCE_RECREATE=0

fingerprint() {
  { cat "$0"; printf '%s\n' "$@"; } | sha256sum | cut -c1-16
}

# exit 0 if every named container is running with the given fingerprint
containers_current() {
  local fp="$1" c state
  shift
  [ "$FORCE_RECREATE" = 0 ] || return 1
  for c in "$@"; do
    state="$(podman inspect -f "{{.State.Running}} {{index .Config.Labels \"$FINGERPRINT_LABEL\"}}" "$c" 2>/dev/null || true)"
    [ "$state" = "true $fp" ] || return 1
  done
}

ensure_op_signed_in() {
  if op whoami >/dev/null 2>&1; then
    return 0
  fi
  echo "sandbox-proxy: not signed in to 1Password, running 'op signin'..." >&2
  local signin_exports
  if ! signin_exports="$(op signin)"; then
    echo "sandbox-proxy: op signin failed" >&2
    exit 1
  fi
  # Without the desktop app integration, op signin prints the session
  # export to apply (with it, it prints nothing)
  eval "$signin_exports"
}

# Reads the username/password fields of the 1Password item with the given
# title. Sets CRED_USER/CRED_PASS. With "password-only", a missing username
# is allowed (bearer tokens).
op_get_creds() {
  local item="$1" mode="${2:-}" json
  if ! command -v op >/dev/null 2>&1; then
    echo "sandbox-proxy: 1Password CLI (op) not found" >&2
    exit 1
  fi
  ensure_op_signed_in
  # With the 1Password desktop app integration this waits for you to
  # approve the access in the app
  echo "sandbox-proxy: reading '$item' from 1Password (approve it in the 1Password app if asked)..." >&2
  if ! json="$(op item get "$item" --fields label=username,label=password --reveal --format json 2>&1)"; then
    echo "sandbox-proxy: could not read 1Password item '$item': $json" >&2
    exit 1
  fi
  # op returns a bare object (not an array) when only one field matches
  CRED_USER="$(jq -r '[.] | flatten | .[] | select(.label=="username") | .value // empty' <<< "$json")"
  CRED_PASS="$(jq -r '[.] | flatten | .[] | select(.label=="password") | .value // empty' <<< "$json")"
  if [ -z "$CRED_PASS" ] || { [ "$mode" != password-only ] && [ -z "$CRED_USER" ]; }; then
    echo "sandbox-proxy: 1Password item '$item' is missing a username or password field" >&2
    exit 1
  fi
}

# The shared Artifactory credential lives in a 1Password item titled exactly
# the Artifactory hostname. Sets ARTIFACTORY_USER/ARTIFACTORY_PASS.
op_get_artifactory_creds() {
  op_get_creds "$1"
  ARTIFACTORY_USER="$CRED_USER"
  ARTIFACTORY_PASS="$CRED_PASS"
}

# Creates the named network with the given subnet, recreating it (after
# removing the listed containers attached to it) if it exists with another
# subnet. Fixed subnets let sandboxes --add-host straight to known proxy IPs.
ensure_network() {
  local name="$1" subnet="$2" existing_subnet
  shift 2
  if podman network exists "$name"; then
    existing_subnet="$(podman network inspect "$name" --format '{{(index .Subnets 0).Subnet}}' 2>/dev/null || true)"
    if [ "$existing_subnet" != "$subnet" ]; then
      podman rm -f "$@" >/dev/null 2>&1 || true
      podman network rm "$name" >/dev/null 2>&1 || true
    fi
  fi
  podman network exists "$name" || podman network create --subnet "$subnet" "$name" >/dev/null
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
    local goproxy_line goproxy first_entry no_scheme no_userinfo
    goproxy_line="$(grep -m1 '^export GOPROXY=' "$HOME/.custom" || true)"
    if [ -n "$goproxy_line" ]; then
      goproxy="${goproxy_line#export GOPROXY=}"
      case "$goproxy" in
        \"*\") goproxy="${goproxy#\"}"; goproxy="${goproxy%\"}" ;;
        \'*\') goproxy="${goproxy#\'}"; goproxy="${goproxy%\'}" ;;
      esac
      # GOPROXY may carry a fallback chain after ours (see cmd_host_login) --
      # only our own entry (the first one) is relevant here.
      first_entry="${goproxy%%,*}"
      no_scheme="${first_entry#https://}"
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
  touch "$HOME/.custom"
  local host="${1:-}"
  if [ -z "$host" ]; then
    echo "sandbox-proxy: host-login requires a hostname" >&2
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
      *) echo "sandbox-proxy: unknown host-login option: $1" >&2; exit 1 ;;
    esac
  done

  op_get_artifactory_creds "$host"

  echo "$ARTIFACTORY_PASS" | podman login "$host" -u "$ARTIFACTORY_USER" --password-stdin
  echo "sandbox-proxy: podman login succeeded for $host"

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
    echo "sandbox-proxy: updated $npmrc for $host/$npm_path"
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
    echo "sandbox-proxy: updated $custom (GOPROXY) for $host/$go_path"
  fi

  if [ -n "$docker_repo" ]; then
    local custom
    custom="$HOME/.custom"
    grep -v '^export ARTIFACTORY_DOCKER_REPO=' "$custom" > "$custom.tmp" || true
    mv "$custom.tmp" "$custom"
    echo "export ARTIFACTORY_DOCKER_REPO=$docker_repo" >> "$custom"
    echo "sandbox-proxy: updated $custom (ARTIFACTORY_DOCKER_REPO) for $host/$docker_repo"
  fi
}

# Starts the given service, or every configured service
cmd_start() {
  local only="${1:-}" started=0
  if [ -n "$only" ] && [ "$only" != registry ] && [ "$only" != mcp ]; then
    usage
    exit 1
  fi
  # Sandboxes launched together (ct start A B C) start in parallel; one
  # at a time checks and, if needed, (re)creates the shared containers.
  # The lock must be released explicitly: podman's conmon (and anything else
  # started here) inherits fd 8 and outlives this script, so merely exiting
  # would leave the lock held and hang every later start. LOCK_UN on the
  # shared open file description frees it for good.
  mkdir -p "$RUNTIME_DIR"
  exec 8>"$RUNTIME_DIR/start.lock"
  if ! flock -n 8; then
    echo "sandbox-proxy: waiting for another sandbox-proxy start to finish (at most 2 minutes)..." >&2
    if ! flock -w 120 8; then
      echo "sandbox-proxy: another sandbox-proxy start has held $RUNTIME_DIR/start.lock for 2 minutes; giving up" >&2
      exit 1
    fi
  fi
  trap 'flock -u 8 2>/dev/null || true' EXIT
  if [ "$only" != mcp ] && cmd_configured; then
    start_registry
    started=1
  fi
  if [ "$only" != registry ] && cmd_mcp_configured; then
    start_mcp
    started=1
  fi
  if [ "$started" = 0 ]; then
    echo "sandbox-proxy: nothing configured -- run 'sandbox-proxy host-login ...' or 'sandbox-proxy mcp add ...' first" >&2
    exit 1
  fi
}

start_registry() {
  discover_config
  local fp containers=(registry-proxy registry-cache)
  [ -n "$NPM_PATH" ] && containers+=(npm-proxy)
  fp="$(fingerprint "$ARTIFACTORY_HOST" "$NPM_PATH" "$GO_PATH" "$DOCKER_REPO" "$REGISTRY_PROXY_CADDYFILE")"
  if containers_current "$fp" "${containers[@]}"; then
    echo "sandbox-proxy: registry proxies already running for $ARTIFACTORY_HOST"
    return 0
  fi

  op_get_artifactory_creds "$ARTIFACTORY_HOST"
  local auth_b64
  auth_b64="$(printf '%s:%s' "$ARTIFACTORY_USER" "$ARTIFACTORY_PASS" | base64 -w0)"

  # Caddy's host-matched HTTPS block, strips the trailing-slash
  # prefix before forwarding to Verdaccio
  local npm_strip_prefix="${NPM_PATH%/}"
  if [ -z "$npm_strip_prefix" ]; then
    npm_strip_prefix="/__no_npm_repo_configured__"
  fi

  ensure_network "$NETWORK_NAME" "$NETWORK_SUBNET" registry-proxy registry-cache npm-proxy
  mkdir -p "$CACHE_DIR"

  podman run -d --replace 8>&- \
    --label "$FINGERPRINT_LABEL=$fp" \
    --name registry-proxy \
    --network "$NETWORK_NAME" \
    --network-alias registry-proxy \
    --ip "$REGISTRY_PROXY_IP" \
    -e ARTIFACTORY_HOST="$ARTIFACTORY_HOST" \
    -e ARTIFACTORY_BASIC_AUTH="$auth_b64" \
    -e NPM_STRIP_PREFIX="$npm_strip_prefix" \
    -v "$REGISTRY_PROXY_CADDYFILE:/etc/caddy/Caddyfile:ro" \
    "$CADDY_IMAGE"

  podman run -d --replace 8>&- \
    --label "$FINGERPRINT_LABEL=$fp" \
    --name registry-cache \
    --network "$NETWORK_NAME" --network-alias registry-cache \
    -e REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=/var/lib/registry \
    -e REGISTRY_PROXY_REMOTEURL="https://$ARTIFACTORY_HOST" \
    -e REGISTRY_PROXY_USERNAME="$ARTIFACTORY_USER" \
    -e REGISTRY_PROXY_PASSWORD="$ARTIFACTORY_PASS" \
    -v "$CACHE_DIR:/var/lib/registry" \
    "$REGISTRY_IMAGE"

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

    podman run -d --replace 8>&- \
      --label "$FINGERPRINT_LABEL=$fp" \
      --name npm-proxy \
      --network "$NETWORK_NAME" --network-alias npm-proxy \
      -e ARTIFACTORY_TOKEN="$ARTIFACTORY_PASS" \
      -e VERDACCIO_PUBLIC_URL="https://$ARTIFACTORY_HOST$NPM_PATH" \
      -v "$NPM_PROXY_CONFIG_DIR/verdaccio-config.yaml:/verdaccio/conf/config.yaml:ro" \
      -v "$NPM_PROXY_STORAGE_VOLUME:/verdaccio/storage" \
      "$VERDACCIO_IMAGE"
  fi

  local path_shown="${NPM_PATH:-${GO_PATH:-unset}}"
  echo "sandbox-proxy: started for $ARTIFACTORY_HOST (npm/go path: $path_shown)"
}

# The npm cache (Verdaccio's volume) keeps every tarball ever fetched; drop
# the ones not fetched again for --days (default 60). Verdaccio refetches a
# missing one from Artifactory on demand. The image cache (registry:2 in
# proxy mode) expires blobs by itself (7 days).
cmd_prune() {
  local days=60
  if [ "${1:-}" = --days ]; then
    days="${2:-}"
  fi
  case "$days" in
    ""|*[!0-9]*) echo "sandbox-proxy: prune --days needs a number" >&2; exit 1 ;;
  esac
  podman volume exists "$NPM_PROXY_STORAGE_VOLUME" || { echo "sandbox-proxy: no npm cache to prune"; return 0; }
  podman run --rm -v "$NPM_PROXY_STORAGE_VOLUME:/storage" "$DEBIAN_IMAGE" \
    sh -c "find /storage -name '*.tgz' -atime +$days -print -delete | wc -l | xargs echo 'sandbox-proxy: removed npm tarballs:'; du -sh /storage"
}

cmd_stop() {
  podman rm -f registry-proxy registry-cache npm-proxy mcp-proxy 2>/dev/null || true
}

cmd_status() {
  podman ps --filter "network=$NETWORK_NAME"
  podman ps --filter "network=$MCP_NETWORK_NAME" --noheading
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
    echo "sandbox-proxy: no npm registry configured (run host-login --npm-repo first)" >&2
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
    echo "sandbox-proxy: no registry configured (run host-login first)" >&2
    exit 1
  fi
  echo "$ARTIFACTORY_HOST:$REGISTRY_PROXY_IP"
}

cmd_sandbox_goproxy() {
  discover_config
  if [ -z "$GO_PATH" ]; then
    echo "sandbox-proxy: no go registry configured (run host-login --go-repo first)" >&2
    exit 1
  fi
  echo "http://registry-proxy:7080$GO_PATH"
}

# Prints the full mirror prefix to scope the docker registries.conf mirror to
cmd_sandbox_docker_prefix() {
  discover_config
  if [ -z "$ARTIFACTORY_HOST" ]; then
    echo "sandbox-proxy: no registry configured (run host-login first)" >&2
    exit 1
  fi
  if [ -n "$DOCKER_REPO" ]; then
    echo "$ARTIFACTORY_HOST/$DOCKER_REPO"
  else
    echo "$ARTIFACTORY_HOST"
  fi
}

# --- MCP service ---

mcp_config_json() {
  if [ -s "$MCP_CONFIG" ]; then cat "$MCP_CONFIG"; else echo '{}'; fi
}

valid_mcp_name() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]
}

cmd_mcp() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    add) cmd_mcp_add "$@" ;;
    remove)
      local name="${1:-}"
      if ! valid_mcp_name "$name"; then
        echo "sandbox-proxy: mcp remove requires a server name" >&2
        exit 1
      fi
      mkdir -p "$(dirname "$MCP_CONFIG")"
      mcp_config_json | jq --arg n "$name" 'del(.[$n])' > "$MCP_CONFIG.tmp"
      mv "$MCP_CONFIG.tmp" "$MCP_CONFIG"
      write_host_mcp_config
      echo "sandbox-proxy: removed MCP server '$name' (the proxy is updated on the next sandbox start; running sandboxes keep it until restarted)"
      ;;
    list)
      mcp_config_json | jq -r 'to_entries[] | "\(.key)\t\(.value.url)\t1password:\(.value.opItem)\t\(.value.auth)"'
      ;;
    *) usage; exit 1 ;;
  esac
}

cmd_mcp_add() {
  local name="${1:-}" url="" op_item="" auth="basic"
  if ! valid_mcp_name "$name"; then
    echo "sandbox-proxy: mcp add requires a name matching [a-z0-9-]+" >&2
    exit 1
  fi
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --url) url="${2:-}"; shift 2 ;;
      --op-item) op_item="${2:-}"; shift 2 ;;
      --auth) auth="${2:-}"; shift 2 ;;
      *) echo "sandbox-proxy: unknown mcp add option: $1" >&2; exit 1 ;;
    esac
  done
  if ! [[ "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]]; then
    echo "sandbox-proxy: --url must be an https:// URL (no query string)" >&2
    exit 1
  fi
  if [ -z "$op_item" ]; then
    echo "sandbox-proxy: --op-item is required" >&2
    exit 1
  fi
  if [ "$auth" != basic ] && [ "$auth" != bearer ]; then
    echo "sandbox-proxy: --auth must be basic or bearer" >&2
    exit 1
  fi

  # Fail early if the credential isn't readable
  if [ "$auth" = basic ]; then op_get_creds "$op_item"; else op_get_creds "$op_item" password-only; fi

  mkdir -p "$(dirname "$MCP_CONFIG")"
  mcp_config_json | jq --arg n "$name" --arg u "$url" --arg i "$op_item" --arg a "$auth" \
    '.[$n] = {url: $u, opItem: $i, auth: $a}' > "$MCP_CONFIG.tmp"
  mv "$MCP_CONFIG.tmp" "$MCP_CONFIG"
  write_host_mcp_config
  echo "sandbox-proxy: added MCP server '$name' -> $url (the proxy is updated on the next sandbox start; running sandboxes need a restart to see it)"
}

# exit 0 if at least one MCP server is configured, 1 otherwise
cmd_mcp_configured() {
  [ "$(mcp_config_json | jq 'length')" -gt 0 ]
}

# Generates a Caddyfile with one route per MCP server. Secrets are only
# referenced as {$MCP_AUTH_<NAME>} env placeholders and passed to the
# container via -e, never written to disk.
start_mcp() {
  local config names name url auth op_item scheme_host host path env_name
  local env_flags=() fp
  config="$(mcp_config_json)"
  mapfile -t names < <(jq -r 'keys[]' <<< "$config")

  mkdir -p "$RUNTIME_DIR"
  local caddyfile="$RUNTIME_DIR/mcp-Caddyfile"
  # Reuse the running proxy unless the server list changed (secrets aren't
  # part of the fingerprint: `restart mcp` after rotating one). The generated
  # Caddyfile lives in the runtime dir, so it must still be there too.
  fp="$(fingerprint "$config" "$MCP_HOST_PORT")"
  write_host_mcp_config
  if [ -s "$caddyfile" ] && containers_current "$fp" mcp-proxy; then
    echo "sandbox-proxy: MCP proxy already running for: ${names[*]}"
    return 0
  fi
  {
    echo "{"
    echo "	auto_https off"
    echo "}"
    echo ":$MCP_PROXY_PORT {"
  } > "$caddyfile"

  for name in "${names[@]}"; do
    valid_mcp_name "$name" || continue
    url="$(jq -r --arg n "$name" '.[$n].url' <<< "$config")"
    auth="$(jq -r --arg n "$name" '.[$n].auth' <<< "$config")"
    op_item="$(jq -r --arg n "$name" '.[$n].opItem' <<< "$config")"
    scheme_host="$(sed -E 's#^(https://[^/]+).*#\1#' <<< "$url")"
    host="${scheme_host#https://}"
    path="${url#"$scheme_host"}"
    path="${path:-/}"
    env_name="MCP_AUTH_$(tr 'a-z-' 'A-Z_' <<< "$name")"

    if [ "$auth" = bearer ]; then
      op_get_creds "$op_item" password-only
      env_flags+=(-e "$env_name=Bearer $CRED_PASS")
    else
      op_get_creds "$op_item"
      env_flags+=(-e "$env_name=Basic $(printf '%s:%s' "$CRED_USER" "$CRED_PASS" | base64 -w0)")
    fi

    cat >> "$caddyfile" <<EOF
	handle /$name {
		rewrite * $path
		reverse_proxy $scheme_host {
			header_up Host ${host%%:*}
			header_up Authorization "{\$$env_name}"
			flush_interval -1
		}
	}
EOF
  done

  {
    echo "	respond 404"
    echo "}"
  } >> "$caddyfile"

  ensure_network "$MCP_NETWORK_NAME" "$MCP_NETWORK_SUBNET" mcp-proxy

  podman run -d --replace 8>&- \
    --label "$FINGERPRINT_LABEL=$fp" \
    --name mcp-proxy \
    --network "$MCP_NETWORK_NAME" \
    --network-alias mcp-proxy \
    -p "127.0.0.1:$MCP_HOST_PORT:$MCP_PROXY_PORT" \
    "${env_flags[@]}" \
    -v "$caddyfile:/etc/caddy/Caddyfile:ro" \
    "$CADDY_IMAGE" >/dev/null

  echo "sandbox-proxy: MCP proxy started for: ${names[*]}"
}

# The credential-free MCP config of the host URLs (127.0.0.1)
cmd_host_mcp_config() {
  mcp_config_json | jq -c --arg port "$MCP_HOST_PORT" '{mcpServers: (to_entries
    | map(select(.key | test("^[a-z0-9][a-z0-9-]*$")))
    | map({key, value: {type: "http", url: "http://127.0.0.1:\($port)/\(.key)"}})
    | from_entries)}'
}
write_host_mcp_config() {
  mkdir -p "$(dirname "$MCP_HOST_CONFIG")"
  cmd_host_mcp_config > "$MCP_HOST_CONFIG.tmp" && mv "$MCP_HOST_CONFIG.tmp" "$MCP_HOST_CONFIG"
}

# Prints the credential-free MCP config claude-sandbox passes to claude
cmd_sandbox_mcp_config() {
  mcp_config_json | jq -c --arg port "$MCP_PROXY_PORT" '{mcpServers: (to_entries
    | map(select(.key | test("^[a-z0-9][a-z0-9-]*$")))
    | map({key, value: {type: "http", url: "http://mcp-proxy:\($port)/\(.key)"}})
    | from_entries)}'
}

case "${1:-}" in
  host-login) shift; cmd_host_login "$@" ;;
  start) shift; cmd_start "$@" ;;
  restart) shift; FORCE_RECREATE=1; cmd_start "$@" ;;
  stop) cmd_stop ;;
  prune) shift; cmd_prune "$@" ;;
  status) cmd_status ;;
  configured) cmd_configured ;;
  sandbox-npmrc) cmd_sandbox_npmrc ;;
  sandbox-goproxy) cmd_sandbox_goproxy ;;
  sandbox-docker-prefix) cmd_sandbox_docker_prefix ;;
  sandbox-extra-host) cmd_sandbox_extra_host ;;
  mcp) shift; cmd_mcp "$@" ;;
  mcp-configured) cmd_mcp_configured ;;
  sandbox-mcp-config) cmd_sandbox_mcp_config ;;
  host-mcp-config) cmd_host_mcp_config ;;
  *) usage; exit 1 ;;
esac
