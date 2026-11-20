RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/sandbox-proxy"

NETWORK_NAME="sandbox-registry"
NETWORK_SUBNET="172.30.99.0/24"
REGISTRY_PROXY_IP="172.30.99.2"
CACHE_DIR="$HOME/.local/share/registry-cache"
NPM_PROXY_STORAGE_VOLUME="npm-proxy-storage"
NPM_PROXY_CONFIG_DIR="$RUNTIME_DIR"

MCP_NETWORK_NAME="sandbox-mcp"
MCP_NETWORK_SUBNET="172.30.98.0/24"
MCP_PROXY_PORT=8080
MCP_HOST_PORT="${SANDBOX_PROXY_MCP_HOST_PORT:-47180}"
MCP_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/sandbox-proxy/mcp-servers.json"
MCP_HOST_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/sandbox-proxy/mcp-host.json"

usage() {
  cat >&2 <<'USAGE'
Usage:
  sandbox-proxy host-login <host> --npm-repo <repo> --go-repo <repo> --docker-repo <repo> [--maven-repo <repo>]
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
  sandbox-proxy sandbox-maven-settings
  sandbox-proxy sandbox-maven-repo-url
  sandbox-proxy sandbox-gradle-init
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

CADDY_IMAGE="docker.io/library/caddy:2.11.9@sha256:0c2243efcf437ab7f7a978f1027fcf0d4f9be8a75df27b1b3fbc5dbe0ffa8cf0"
REGISTRY_IMAGE="docker.io/library/registry:3.1.2@sha256:82f6ff4a7f982960c8aa51617fea3aabc485df6e55cce80d22deb1de36f1bc3c"
VERDACCIO_IMAGE="docker.io/verdaccio/verdaccio:7.1.2@sha256:4addf64c2fd5f86e963444e8a482d7cd20cd2243e01470d548bdb23d0cd609de"
DEBIAN_IMAGE="docker.io/library/debian:trixie-20261104-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2"

FINGERPRINT_LABEL="sandbox-proxy.fingerprint"
FORCE_RECREATE=0

fingerprint() {
  { cat "$0"; printf '%s\n' "$@"; } | sha256sum | cut -c1-16
}

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

op_get_creds() {
  local item="$1" mode="${2:-}" json
  if ! command -v op >/dev/null 2>&1; then
    echo "sandbox-proxy: 1Password CLI (op) not found" >&2
    exit 1
  fi
  ensure_op_signed_in
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

op_get_artifactory_creds() {
  op_get_creds "$1"
  ARTIFACTORY_USER="$CRED_USER"
  ARTIFACTORY_PASS="$CRED_PASS"
}

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

discover_config() {
  ARTIFACTORY_HOST="" NPM_PATH="" GO_PATH="" DOCKER_REPO="" MAVEN_REPO=""

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
      first_entry="${goproxy%%,*}"
      no_scheme="${first_entry#https://}"
      no_scheme="${no_scheme#http://}"

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

    local maven_repo_line
    maven_repo_line="$(grep -m1 '^export ARTIFACTORY_MAVEN_REPO=' "$HOME/.custom" || true)"
    if [ -n "$maven_repo_line" ]; then
      MAVEN_REPO="${maven_repo_line#export ARTIFACTORY_MAVEN_REPO=}"
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

  local npm_repo="" go_repo="" docker_repo="" maven_repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --npm-repo) npm_repo="$2"; shift 2 ;;
      --go-repo) go_repo="$2"; shift 2 ;;
      --docker-repo) docker_repo="$2"; shift 2 ;;
      --maven-repo) maven_repo="$2"; shift 2 ;;
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
    local go_path="artifactory/api/go/$go_repo" custom enc_user enc_pass goproxy_url
    local existing_goproxy fallback
    enc_user="$(jq -rn --arg s "$ARTIFACTORY_USER" '$s|@uri')"
    enc_pass="$(jq -rn --arg s "$ARTIFACTORY_PASS" '$s|@uri')"
    goproxy_url="https://$enc_user:$enc_pass@$host/$go_path"
    custom="$HOME/.custom"

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

  if [ -n "$maven_repo" ]; then
    if ! [[ "$maven_repo" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      echo "sandbox-proxy: --maven-repo takes a repository key, not '$maven_repo'" >&2
      exit 1
    fi
    grep -v '^export ARTIFACTORY_MAVEN_REPO=' "$HOME/.custom" > "$HOME/.custom.tmp" || true
    mv "$HOME/.custom.tmp" "$HOME/.custom"
    echo "export ARTIFACTORY_MAVEN_REPO=$maven_repo" >> "$HOME/.custom"
    echo "sandbox-proxy: updated $HOME/.custom (ARTIFACTORY_MAVEN_REPO) for $host/$maven_repo"
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

cmd_start() {
  local only="${1:-}" started=0
  if [ -n "$only" ] && [ "$only" != registry ] && [ "$only" != mcp ]; then
    usage
    exit 1
  fi
  # podman's conmon inherits fd 8 and outlives this script: the lock is
  # released explicitly (LOCK_UN), not by exiting
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

cmd_configured() {
  discover_config
  [ -n "$ARTIFACTORY_HOST" ]
}

cmd_sandbox_npmrc() {
  discover_config
  if [ -z "$NPM_PATH" ]; then
    echo "sandbox-proxy: no npm registry configured (run host-login --npm-repo first)" >&2
    exit 1
  fi

  echo "strict-ssl=false"
  echo "registry=https://$ARTIFACTORY_HOST$NPM_PATH"
}

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

require_maven_repo() {
  discover_config
  if [ -z "$MAVEN_REPO" ]; then
    echo "sandbox-proxy: no maven repository configured (run host-login --maven-repo first)" >&2
    exit 1
  fi
}

cmd_sandbox_maven_repo_url() {
  require_maven_repo
  echo "http://registry-proxy:7080/artifactory/$MAVEN_REPO"
}

cmd_sandbox_gradle_init() {
  require_maven_repo
  cat <<INIT
def artifactoryHost = '$ARTIFACTORY_HOST'
def redirect = { repo ->
    if (repo instanceof MavenArtifactRepository && repo.url?.host == artifactoryHost) {
        repo.url = 'http://registry-proxy:7080' + repo.url.path
        repo.allowInsecureProtocol = true
    }
}
settingsEvaluated { settings ->
    settings.pluginManagement.repositories.configureEach(redirect)
    if (GradleVersion.current() >= GradleVersion.version('6.8')) {
        settings.dependencyResolutionManagement.repositories.configureEach(redirect)
    }
}
allprojects {
    buildscript.repositories.configureEach(redirect)
    repositories.configureEach(redirect)
}
INIT
}

cmd_sandbox_maven_settings() {
  require_maven_repo
  cat <<SETTINGS
<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0">
  <mirrors>
    <mirror>
      <id>sandbox-proxy</id>
      <mirrorOf>*</mirrorOf>
      <url>http://registry-proxy:7080/artifactory/$MAVEN_REPO/</url>
    </mirror>
  </mirrors>
</settings>
SETTINGS
}

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

  if [ "$auth" = basic ]; then op_get_creds "$op_item"; else op_get_creds "$op_item" password-only; fi

  mkdir -p "$(dirname "$MCP_CONFIG")"
  mcp_config_json | jq --arg n "$name" --arg u "$url" --arg i "$op_item" --arg a "$auth" \
    '.[$n] = {url: $u, opItem: $i, auth: $a}' > "$MCP_CONFIG.tmp"
  mv "$MCP_CONFIG.tmp" "$MCP_CONFIG"
  write_host_mcp_config
  echo "sandbox-proxy: added MCP server '$name' -> $url (the proxy is updated on the next sandbox start; running sandboxes need a restart to see it)"
}

cmd_mcp_configured() {
  [ "$(mcp_config_json | jq 'length')" -gt 0 ]
}

start_mcp() {
  local config names name auth op_item env_name guard_config
  local env_flags=() fp
  : "${MCP_GUARD:?sandbox-proxy: MCP_GUARD is unset (run the sandbox-proxy package, not the script)}"
  : "${MCP_POLICIES:?sandbox-proxy: MCP_POLICIES is unset (run the sandbox-proxy package, not the script)}"
  config="$(mcp_config_json)"
  mapfile -t names < <(jq -r 'keys[]' <<< "$config")

  mkdir -p "$RUNTIME_DIR"
  guard_config="$RUNTIME_DIR/mcp-guard.json"
  fp="$(fingerprint "$config" "$MCP_HOST_PORT" "$MCP_GUARD" "$(cat "$MCP_POLICIES")")"
  write_host_mcp_config
  if [ -s "$guard_config" ] && containers_current "$fp" mcp-proxy; then
    echo "sandbox-proxy: MCP proxy already running for: ${names[*]}"
    return 0
  fi

  jq -n --argjson servers "$config" --slurpfile policies "$MCP_POLICIES" --arg listen ":$MCP_PROXY_PORT" '
    {listen: $listen, servers: ($servers | with_entries(select(.key | test("^[a-z0-9-]+$")) | .value = (
      {upstream: .value.url, authEnv: ("MCP_AUTH_" + (.key | ascii_upcase | gsub("-"; "_")))}
      + ($policies[0][.key] // {})
    )))}' > "$guard_config.tmp"
  mv "$guard_config.tmp" "$guard_config"

  for name in "${names[@]}"; do
    valid_mcp_name "$name" || continue
    auth="$(jq -r --arg n "$name" '.[$n].auth' <<< "$config")"
    op_item="$(jq -r --arg n "$name" '.[$n].opItem' <<< "$config")"
    env_name="MCP_AUTH_$(tr 'a-z-' 'A-Z_' <<< "$name")"

    if [ "$auth" = bearer ]; then
      op_get_creds "$op_item" password-only
      env_flags+=(-e "$env_name=Bearer $CRED_PASS")
    else
      op_get_creds "$op_item"
      env_flags+=(-e "$env_name=Basic $(printf '%s:%s' "$CRED_USER" "$CRED_PASS" | base64 -w0)")
    fi
  done

  ensure_network "$MCP_NETWORK_NAME" "$MCP_NETWORK_SUBNET" mcp-proxy

  podman run -d --replace 8>&- \
    --label "$FINGERPRINT_LABEL=$fp" \
    --name mcp-proxy \
    --network "$MCP_NETWORK_NAME" \
    --network-alias mcp-proxy \
    -p "127.0.0.1:$MCP_HOST_PORT:$MCP_PROXY_PORT" \
    "${env_flags[@]}" \
    -v "$MCP_GUARD:/usr/local/bin/mcp-guard:ro" \
    -v "$guard_config:/etc/mcp-guard.json:ro" \
    --entrypoint /usr/local/bin/mcp-guard \
    "$CADDY_IMAGE" -config /etc/mcp-guard.json >/dev/null

  echo "sandbox-proxy: MCP proxy started for: ${names[*]}"
}

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
  sandbox-maven-settings) cmd_sandbox_maven_settings ;;
  sandbox-maven-repo-url) cmd_sandbox_maven_repo_url ;;
  sandbox-gradle-init) cmd_sandbox_gradle_init ;;
  sandbox-extra-host) cmd_sandbox_extra_host ;;
  mcp) shift; cmd_mcp "$@" ;;
  mcp-configured) cmd_mcp_configured ;;
  sandbox-mcp-config) cmd_sandbox_mcp_config ;;
  host-mcp-config) cmd_host_mcp_config ;;
  *) usage; exit 1 ;;
esac
