agent="${SANDBOX_AGENT:-claude}"
case "$agent" in
  claude|kiro) ;;
  *) echo "claude-sandbox: unknown SANDBOX_AGENT '$agent' (claude or kiro)" >&2; exit 1 ;;
esac
sandbox_name="$agent-sandbox"
for old in $(compgen -e | grep -E '^(CLAUDE|KIRO)_SANDBOX_(PORTS|NAME|QUIET|PASS_ENV|RO_PATHS|NIX_DAEMON|ADD_DIRS|TRUST_ALL)$' || true); do
  echo "$sandbox_name: $old is no longer read; use ${old#*_}" >&2
done

launch_log="${XDG_STATE_HOME:-$HOME/.local/state}/$sandbox_name.log"
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
  printf '%s [%d.%ds] %s\n' "$sandbox_name" $((ms / 1000)) $(((ms % 1000) / 100)) "$1"
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

if [[ "${SANDBOX_AS:-}" == kiro-sandbox && "${1:-}" =~ ^(-h|--help)$ ]]; then
  cat <<'EOF'
Usage: kiro [kiro-cli args...]        (kiro-sandbox is the same command)

Runs kiro-cli inside a sandboxed, privileged rootless podman container,
scoped to the current directory. The arguments are kiro-cli's own and are
passed through (`kiro chat --help` lists them; no arguments starts a chat);
kiro-open runs the unsandboxed CLI.

Chats trust every tool: no arguments or `chat ...` runs
`kiro-cli chat --trust-all-tools ...`, as the container is the boundary (git
pushes still go through git-ssh-broker, which refuses deletes and force
pushes but rewrites of your own commits on feature/*). A trust flag of your own (-a, --trust-all-tools, --trust-tools=...)
is left as given, and SANDBOX_TRUST_ALL=0 keeps kiro's prompts.

What the session can see and change:
  * read-write: the current directory and every SANDBOX_ADD_DIRS
    directory
  * read-only: programs.kiroSandbox.readOnlyPaths and SANDBOX_RO_PATHS,
    /nix/store, the asdf data dir, any vault's .obsidian/, and in every
    clone under a read-write directory .git/config and .git/hooks (as in
    claude-sandbox)
  * kiro's own state is the sandbox's, not the host's: ~/.kiro and
    ~/.local/share/kiro-cli are ~/.local/share/kiro-sandbox/{kiro,data},
    so sessions, workspace trust and "always allow" rules given in the
    sandbox stay in the sandbox and never reach kiro-open. So is the login:
    a chat started while the sandbox isn't logged in runs
    `kiro-cli login --use-device-flow` first, and the login is kept
  * from the host, read-only: ~/.kiro/{agents,skills,steering,hooks,powers}
    and a throwaway copy of ~/.kiro/settings, whose mcp.json is the host's
    servers plus sandbox-proxy's and programs.kiroSandbox.extraMcpServers;
    settings changed in a session are dropped at exit
  * the CA bundle, the host nix-daemon (untrusted users only), git over SSH
    and commit signing through git-ssh-broker, sandbox-proxy's registries,
    and ~/.tool-versions work as in claude-sandbox (claude-sandbox --help)
  * the language servers of kiro's code tool (/code init) are on PATH
    (programs.kiroSandbox.lspPackages)

Sandbox settings (environment; the same SANDBOX_* for claude-sandbox):
  SANDBOX_PORTS=3000,5173   publish ports on the same host ports, on
                            127.0.0.1 only (0.0.0.0:3000: every interface,
                            for another device; to open a ticket's apps
                            on this machine, tix ws run / tix ws browse)
  SANDBOX_NAME=<label>      pod kiro-sandbox-<label>
  SANDBOX_QUIET=1           only print warnings while launching
  SANDBOX_PASS_ENV="A_* B"  more host variables to pass in (name globs,
                            added to programs.kiroSandbox.passEnv)
  SANDBOX_ADD_DIRS=/a:~/b   more directories mounted read-write (mounts
                            only; tix sets it for the vault's sessions)
  SANDBOX_RO_PATHS=/a:~/b   more host paths mounted read-only at the same
                            path (added to the configured list)
  SANDBOX_NIX_DAEMON=1      mount the nix-daemon socket when its trust
                            can't be told
  SANDBOX_TRUST_ALL=0       chats ask before running tools (kiro's
                            default) instead of trusting them all
  SANDBOX_GIT_AUTOSIGN=0    commits and tags aren't signed unless asked
                            (git commit -S, tix ws resign); the signing
                            agent stays available (tix sessions set it)

If the current directory is a git checkout, it is fetched and fast-forwarded
to its upstream before launch. Each launch step is logged to
~/.local/state/kiro-sandbox.log.
EOF
  exit 0
fi
if [[ "${SANDBOX_AS:-}" == claude-sandbox && "${1:-}" =~ ^(-h|--help)$ ]]; then
  cat <<'EOF'
Usage: claude [claude args...]        (claude-sandbox is the same command)

Runs Claude Code inside a sandboxed, privileged rootless podman container,
scoped to the current directory. The arguments are claude's own and are
passed through untouched (claude --help lists them); claude-open runs the
unsandboxed CLI.

What the session can see and change follows Claude's own settings:
  * read-write: the current directory, every --add-dir directory (from
    the arguments, and permissions.additionalDirectories in the user,
    project and --settings settings) and every SANDBOX_ADD_DIRS one
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
  * the CA bundle (CACERT_BUNDLE) read-only at /etc/pki/tls/certs/ca-bundle.crt
    and /etc/ssl/certs/ca-certificates.crt: the image has none, and tools that
    ignore SSL_CERT_FILE (Dart/pub reads only these locations) need one there
  * container-only managed settings at /etc/claude-code/managed-settings.json
    that allow kill, pkill, killall, rm, rmdir, unlink and git push, and deny
    force pushes (but --force-with-lease) and deletes; the user settings' denies of the allowed rules
    (rm -rf, git push) are dropped in the container (the host's settings are
    unchanged)
  * the host nix-daemon's socket directory (/nix/var/nix/daemon-socket),
    when it exists, with NIX_REMOTE=daemon: `nix eval` and `nix flake check
    --no-build` work in the sandbox. Trade-off: anything in the sandbox can
    talk to the daemon as the invoking user, so it can ask the host to
    evaluate, fetch and build things, not just read the store; builds run
    on the host, outside the sandbox. /nix/store itself stays read-only.
    That is safe only for an untrusted nix user: the launcher asks the
    daemon (`nix store info --json`) and skips the mount, with a warning,
    when you are in nix.settings.trusted-users (root-equivalent); if it
    can't tell, it does not mount it either (fails closed) and warns;
    SANDBOX_NIX_DAEMON=1 mounts it anyway in that case (a known-
    trusted user never gets it)
  * git over SSH through git-ssh-broker, started on the host for the
    session: fetch and push to GitHub/Bitbucket with your host ssh setup,
    but never a branch/tag delete, a tag move or a force push (do those on
    the host), except rewriting a feature/* branch when every commit it
    drops is yours (programs.gitSshBroker.rewritableBranches and
    identityEmails: rebasing your own branch and pushing it again); commits are signed through its git-signatures-only agent
    with the configured signing keys (unsigned without a host agent)
  * a main clone's .git given read-write keeps its config and hooks
    read-only, so `git branch -d` there prints "could not write config
    file ... Device or resource busy" (it tries to drop the branch's
    config section) but still deletes the branch; ticket tooling deletes
    refs with `git update-ref -d` after its own merge check
  * ~/.tool-versions, read-only: the host's file if it has one, plus the
    newest installed version of each asdf plugin it doesn't name (all of
    them without a host file), so the asdf shims (python3, go, gofmt)
    work in any directory; a .tool-versions nearer the working
    directory wins

Sandbox settings (environment; the same SANDBOX_* for kiro-sandbox):
  SANDBOX_PORTS=3000,5173   publish ports on the same host ports, on
                            127.0.0.1 only (0.0.0.0:3000: every interface,
                            for another device; to open a ticket's apps
                            on this machine, tix ws run / tix ws browse)
  SANDBOX_NAME=<label>      pod claude-sandbox-<label>
  SANDBOX_QUIET=1           only print warnings while launching
  SANDBOX_PASS_ENV="A_* B"  more host variables to pass in (name globs,
                            added to programs.claudeSandbox.passEnv)
  SANDBOX_ADD_DIRS=/a:~/b   more directories mounted read-write, as
                            --add-dir's are, but only mounted: Claude
                            isn't given them (tix sets it for the vault's
                            sessions)
  SANDBOX_RO_PATHS=/a:~/b   more host paths mounted read-only at the same
                            path in every session, added to programs.
                            claudeSandbox.readOnlyPaths; ~ and $HOME are
                            expanded and a missing path is skipped. Every
                            path is mounted once and read-only wins: one
                            also given read-write (an --add-dir, the
                            project) is read-only, one around a read-write
                            directory leaves that directory writable
  SANDBOX_TRUST_ALL         not used by claude (its container-only managed
                            settings already allow what the sandbox holds)
  SANDBOX_GIT_AUTOSIGN=0    commits and tags aren't signed unless asked
                            (git commit -S, tix ws resign); the signing
                            agent stays available (tix sessions set it:
                            ticket work is signed once, after the tidy)

If the current directory is a git checkout, it is fetched and fast-forwarded
to its upstream before launch; diverged branches or local changes in the
way are reported and left alone. Each launch step is printed with the
seconds since launch, and logged to ~/.local/state/claude-sandbox.log.
EOF
  exit 0
fi

[[ "${SANDBOX_QUIET:-}" == 1 ]] && quiet=1
port_flags=()
IFS=',' read -ra ports <<< "${SANDBOX_PORTS:-}"
for p in "${ports[@]}"; do
  [[ -n "$p" ]] || continue
  # podman publishes a port on every interface unless an address is given
  if [[ "$p" =~ ^[0-9]+$ ]]; then
    port_flags+=(-p "127.0.0.1:$p:$p")
  elif [[ "$p" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}):([0-9]+)$ ]]; then
    port_flags+=(-p "${BASH_REMATCH[1]}:${BASH_REMATCH[3]}:${BASH_REMATCH[3]}")
  else
    echo "$sandbox_name: SANDBOX_PORTS must be a comma-separated list of ports (or <IPv4>:<port>): $p" >&2
    exit 1
  fi
done
name_override="${SANDBOX_NAME:-}"

add_dirs=() settings_args=() mcp_args=() path_args=()
args=("$@")
i=0
take_list() {
  local -n into="$1"
  while (( i + 1 < ${#args[@]} )) && [[ "${args[i + 1]}" != -* ]]; do
    i=$((i + 1))
    into+=("${args[i]}")
  done
}
while [[ "$agent" == claude ]] && (( i < ${#args[@]} )); do
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
IFS=: read -ra env_add_dirs <<< "${SANDBOX_ADD_DIRS:-}"
for d in "${env_add_dirs[@]}"; do
  [[ -n "$d" ]] && add_dirs+=("$d")
done
project_root="$PWD"
log "launching in $project_root (log: $launch_log)"

if git -C "$project_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "updating the git checkout (git fetch, at most 30s)"
  "$CLAUDE_GIT_UPDATE" "$project_root"
fi
asdf_data_dir="$HOME/.asdf"
nix_daemon_socket_dir="$(realpath -m -- "${NIX_DAEMON_SOCKET_DIR:-/nix/var/nix/daemon-socket}")"
if [[ "$nix_daemon_socket_dir" != /nix/var/nix/* && "${SANDBOX_TEST:-}" != 1 ]]; then
  warn "NIX_DAEMON_SOCKET_DIR=$nix_daemon_socket_dir is outside /nix/var/nix/ (only the test may set it): ignoring it"
  nix_daemon_socket_dir=/nix/var/nix/daemon-socket
fi

# shellcheck disable=SC2329 # runs from the EXIT trap
cleanup() {
  local code=$?
  if [[ -z "${claude_started:-}" ]]; then
    log "launch aborted (exit $code)"
  else
    log_line "session ended (exit $code)" >/dev/null
  fi
  [[ -n "${dbus_proxy_pid:-}" ]] && kill "$dbus_proxy_pid" 2>/dev/null || true
  [[ -n "${git_broker_pid:-}" ]] && kill "$git_broker_pid" 2>/dev/null || true
  [[ -n "${review_broker_pid:-}" ]] && kill "$review_broker_pid" 2>/dev/null || true
  if [[ -n "${herdr_watch_pid:-}" ]]; then
    kill "$herdr_watch_pid" 2>/dev/null || true
    herdr_report ""
  fi
  [[ -n "${pod_name:-}" ]] && podman pod rm -f -t 5 "$pod_name" >/dev/null 2>&1 || true
  [[ -n "${tmp_dir:-}" && -d "$tmp_dir" ]] && rm -rf "$tmp_dir"
  [[ -n "${dbus_proxy_dir:-}" && -d "$dbus_proxy_dir" ]] && rm -rf "$dbus_proxy_dir"
  [[ -n "${git_broker_dir:-}" && -d "$git_broker_dir" ]] && rm -rf "$git_broker_dir"
  [[ -n "${review_broker_dir:-}" && -d "$review_broker_dir" ]] && rm -rf "$review_broker_dir"
  [[ -n "${herdr_dir:-}" && -d "$herdr_dir" ]] && rm -rf "$herdr_dir"
  return 0  # under set -e, a false last test above would become the exit status
}
trap cleanup EXIT

if [[ "$agent" == kiro ]]; then
  agent_out="$KIRO_CLI"
  agent_cmd=("$agent_out/bin/kiro-cli")
  log "kiro-cli: $agent_out"
else
  agent_out="$CLAUDE_CODE"
  agent_cmd=("$agent_out/bin/claude")
  log "claude-code: $agent_out"

  if [[ -n "${AGENT_HOME:-}" ]]; then
    [[ "$AGENT_HOME" == /* ]] || { echo "$sandbox_name: AGENT_HOME must be absolute: $AGENT_HOME" >&2; exit 1; }
    claude_home="$AGENT_HOME"
    claude_json="$AGENT_HOME/.claude.json"
    log "profile ${AGENT_PROFILE:-?}: Claude's config in $claude_home"
  else
    claude_home="$HOME/.claude"
    claude_json="$HOME/.claude.json"
  fi
  mkdir -p "$claude_home"
  # a file bind mount needs the file to exist; Claude reports an empty one as a corrupt config
  [[ -s "$claude_json" ]] || echo '{}' > "$claude_json"
fi

network_flags=()
registry_env_flags=()
mounts=()
tmp_dir="$(mktemp -d)"
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

  if sandbox-proxy sandbox-maven-settings > "$tmp_dir/maven-settings.xml" 2>/dev/null; then
    mounts+=(-v "$tmp_dir/maven-settings.xml:$HOME/.m2/settings.xml:ro")
  fi

  if maven_repo_url="$(sandbox-proxy sandbox-maven-repo-url 2>/dev/null)"; then
    registry_env_flags+=(-e "MVNW_REPOURL=$maven_repo_url")
  fi

  if sandbox-proxy sandbox-gradle-init > "$tmp_dir/sandbox-proxy.gradle" 2>/dev/null; then
    mounts+=(-v "$tmp_dir/sandbox-proxy.gradle:$HOME/.gradle/init.d/sandbox-proxy.gradle:ro")
  fi

  if docker_prefix="$(sandbox-proxy sandbox-docker-prefix 2>/dev/null)"; then
    registry_env_flags+=(-e "REGISTRY_MIRROR_PREFIX=$docker_prefix")
  fi

  if extra_host="$(sandbox-proxy sandbox-extra-host 2>/dev/null)"; then
    network_flags+=(--add-host "$extra_host")
  fi
fi

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

git_mounts=()
git_env_flags=()
git_signing=0
if [[ -n "${GIT_SSH_BROKER:-}" ]]; then
  git_broker_dir="$(mktemp -d)"
  broker_args=(serve --git-socket "$git_broker_dir/git.sock")
  [[ -n "${GIT_SSH_BROKER_SSH:-}" ]] && broker_args+=(--ssh "$GIT_SSH_BROKER_SSH")
  IFS=':' read -ra rewritable_branches <<< "${GIT_SSH_BROKER_REWRITABLE_BRANCHES:-}"
  for b in "${rewritable_branches[@]}"; do [[ -n "$b" ]] && broker_args+=(--rewritable-branch "$b"); done
  IFS=':' read -ra identity_emails <<< "${GIT_SSH_BROKER_IDENTITY_EMAILS:-}"
  for e in "${identity_emails[@]}"; do [[ -n "$e" ]] && broker_args+=(--identity-email "$e"); done
  upstream_agent="${SSH_AUTH_SOCK:-${GIT_SSH_BROKER_UPSTREAM_AGENT:-}}"
  upstream_agent="${upstream_agent/#\~/$HOME}"
  signing_keys=()
  IFS=':' read -ra configured_keys <<< "${SANDBOX_SIGNING_KEYS:-}"
  for k in "${configured_keys[@]}"; do
    k="${k/#\~/$HOME}"
    [[ -n "$k" && -f "$k" ]] && signing_keys+=("$k")
  done
  if [[ ${#signing_keys[@]} -gt 0 && -S "$upstream_agent" ]]; then
    broker_args+=(--agent-socket "$git_broker_dir/agent.sock" --upstream-agent "$upstream_agent")
    for k in "${signing_keys[@]}"; do broker_args+=(--signing-key "$k"); done
  elif [[ ${#signing_keys[@]} -gt 0 ]]; then
    warn "no ssh-agent at '$upstream_agent': sessions commit unsigned"
  fi

  log "starting git-ssh-broker (its log: $launch_log)"
  "$GIT_SSH_BROKER" "${broker_args[@]}" 2>> "$launch_log" &
  git_broker_pid=$!
  for _ in $(seq 1 50); do
    [[ -S "$git_broker_dir/git.sock" ]] && break
    sleep 0.1
  done

  if [[ -S "$git_broker_dir/git.sock" ]]; then
    git_mounts+=(-v "$git_broker_dir/git.sock:$git_broker_dir/git.sock")
    git_env_flags+=(
      -e "GIT_SSH_COMMAND=$GIT_SSH_BROKER client"
      -e GIT_SSH_VARIANT=ssh
      -e "GIT_SSH_BROKER_SOCKET=$git_broker_dir/git.sock"
    )
    if [[ -S "$git_broker_dir/agent.sock" ]]; then
      git_signing=1
      git_mounts+=(-v "$git_broker_dir/agent.sock:$git_broker_dir/agent.sock")
      git_env_flags+=(-e "SSH_AUTH_SOCK=$git_broker_dir/agent.sock")
      for k in "${signing_keys[@]}"; do git_mounts+=(-v "$k:$k:ro"); done
      [[ -f "$HOME/.ssh/allowed_signers" ]] && git_mounts+=(-v "$HOME/.ssh/allowed_signers:$HOME/.ssh/allowed_signers:ro")
    fi
  else
    warn "git-ssh-broker didn't come up: no git over SSH in this session"
    kill "$git_broker_pid" 2>/dev/null || true
    git_broker_pid=""
  fi
fi

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
# podman uses the pod name as its hostname, capped at 63 characters (room left for -N)
name_base="$sandbox_name-$name_base"
name_base="${name_base:0:58}"
name_base="${name_base%[-_.]}"

name_labels=(
  --label "$sandbox_name.project=$project_root"
  --label "$sandbox_name.repo=${repo_name:-}"
  --label "$sandbox_name.profile=${AGENT_PROFILE:-}"
)
log "podman: checking for orphaned $sandbox_name pods"
now="$(date +%s)"
while read -r old_pod created; do
  [[ -n "$old_pod" && "$created" =~ ^[0-9]+$ ]] || continue
  [[ "$(podman inspect -f '{{.State.Running}}' "$old_pod-$agent" 2>/dev/null)" == true ]] && continue
  (( now - created > 600 )) || continue
  podman pod rm -f -t 0 "$old_pod" >/dev/null 2>&1 \
    && log "removed the orphaned pod $old_pod"
done < <(podman pod ps --filter "label=$sandbox_name.project" --format '{{.Name}} {{.Created.Unix}}' 2>/dev/null || true)

# podman honours aisandbox.slice only through the pod's cgroup parent, not the systemd-run scope
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
    warn "couldn't create pod $candidate: $create_err"
    exit 1
  fi
done
log "pod $pod_name"

extra_mcp_config=""
if [[ -n "${EXTRA_MCP_CONFIG:-}" ]]; then
  extra_mcp_config="$(cat "$EXTRA_MCP_CONFIG")"
  log "extra MCP servers: $(jq -r '.mcpServers | keys | join(", ")' <<< "$extra_mcp_config" 2>/dev/null)"
fi

# claude's --mcp-config is variadic: a separate value would swallow a following prompt as a config file
mcp_flags=()
if [[ "$agent" == claude && -n "$proxy_mcp_config$extra_mcp_config" ]]; then
  printf '%s\n' "$proxy_mcp_config" "$extra_mcp_config" \
    | jq -s '{mcpServers: (map(select(. != null) | .mcpServers) | add)}' > "$tmp_dir/mcp.json"
  mounts+=(-v "$tmp_dir/mcp.json:$tmp_dir/mcp.json:ro")
  mcp_flags+=("--mcp-config=$tmp_dir/mcp.json")
fi
if [[ "$agent" == claude && -n "${CLAUDE_LSP_PLUGIN:-}" ]]; then
  mcp_flags+=(--plugin-dir "$CLAUDE_LSP_PLUGIN")
fi

settings_sources=()
add_settings() {
  local json
  json="$(cat "$2" 2>/dev/null || true)"
  [[ -n "$json" ]] && jq -e . >/dev/null 2>&1 <<< "$json" \
    && settings_sources+=("$1"$'\t'"$json")
  return 0
}
if [[ "$agent" == claude ]]; then
  add_settings "$claude_home" "$claude_home/settings.json"
  add_settings "$project_root" "$project_root/.claude/settings.json"
  add_settings "$project_root" "$project_root/.claude/settings.local.json"
fi
for s in "${settings_args[@]}"; do
  if [[ "$s" == \{* ]]; then
    jq -e . >/dev/null 2>&1 <<< "$s" && settings_sources+=("$project_root"$'\t'"$s")
  else
    add_settings "$project_root" "$s"
    path_args+=("$s")
  fi
done

abs_path() {
  local p="$1"
  # shellcheck disable=SC2088 # a literal ~ in the rule, expanded by hand
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
    warn "$d isn't a directory, not mounting it"
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
    case "$rule" in
      */\*\*) rule="${rule%/\*\*}" ;;
      */\*) rule="${rule%/\*}" ;;
    esac
    if [[ "$rule" == *"**"* ]]; then
      log "mounts: '$rule' has a ** inside the path, left to the permission rule"
      continue
    fi
    rule="$(abs_path "$rule" "$base")"
    if [[ "$rule" == *[*?[]* ]]; then
      head="${rule%%[*?[]*}"
      tail="${rule#"$head"}"
      comp="${tail%%/*}"
      prefix="${head%/*}"
      if [[ "$head" == */ && ( "$comp" == '*' || "$comp" == '**' ) \
        && -n "$prefix" && -d "$prefix" && "$prefix" != "$(realpath -m "$project_root")" ]]; then
        ro_paths+=("$prefix")
      fi
      # compgen -G keeps a path with spaces whole; mounting a symlink would mount its target's path
      while IFS= read -r m; do
        [[ -n "$m" && -e "$m" && ! -L "$m" ]] && ro_paths+=("$m")
      done < <(compgen -G "$rule" || true)
    elif [[ -e "$rule" ]]; then
      ro_paths+=("$rule")
    fi
  done < <(jq -r '.permissions.deny[]? // empty
    | capture("^(Edit|Write|NotebookEdit)\\((?<p>.+)\\)$")?.p // empty' <<< "${src#*$'\t'}")
done

within() {
  local p="$1" d
  shift
  for d in "$@"; do
    [[ "$p" == "$d" || "$p" == "$d"/* ]] && return 0
  done
  return 1
}

# podman refuses two mounts on one destination and stacks mounts by depth itself
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

IFS=: read -ra extra_ro <<< "${SANDBOX_CONFIG_RO_PATHS:-}:${SANDBOX_RO_PATHS:-}"
for p in "${extra_ro[@]}"; do
  [[ -n "$p" ]] || continue
  # shellcheck disable=SC2088,SC2016 # literal ~ and $HOME in the rule, expanded by hand
  case "$p" in
    "~"|"~/"*) p="$HOME${p#\~}" ;;
    '$HOME'|'$HOME/'*) p="$HOME${p#\$HOME}" ;;
  esac
  if [[ ! -e "$p" ]]; then
    log "read-only path $p is missing, skipping it"
    continue
  fi
  p="$(realpath "$p")" || continue
  [[ -n "$p" ]] || continue
  if [[ "$p" == "$project_abs" ]]; then
    warn "read-only path $p is the project: mounting the project read-only"
    project_mode=ro
    continue
  fi
  [[ "${mount_mode[$p]:-}" == rw ]] && log "mounts: $p is given read-write and read-only: read-only"
  for r in "$project_abs" "${rw_paths[@]}"; do
    if [[ "$r" == "${p%/}"/* ]]; then
      log "mounts: read-only $p contains the read-write $r, which stays read-write"
    fi
  done
  mount_mode[$p]=ro
done

git_dirs=()
for p in "${!mount_mode[@]}"; do
  [[ "${mount_mode[$p]}" == rw && "$(basename "$p")" == .git ]] && git_dirs+=("$p")
done
ro_mounts=()
for p in "${!mount_mode[@]}"; do
  [[ "${mount_mode[$p]}" == ro ]] && ro_mounts+=("$p")
done
scan_dirs=()
[[ "$project_mode" == rw && "$project_abs" != "$HOME" ]] && scan_dirs+=("$project_abs")
for p in "${!mount_mode[@]}"; do
  [[ "${mount_mode[$p]}" == rw && "$(basename "$p")" != .git && "$p" != "$HOME" ]] && scan_dirs+=("$p")
done
git_files=()
for d in "${scan_dirs[@]}"; do
  while IFS= read -r -d '' g; do
    within "$g" "${ro_mounts[@]}" && continue
    if [[ -d "$g" && ! -L "$g" ]]; then
      git_dirs+=("$g")
    elif [[ -f "$g" && ! -L "$g" ]]; then
      git_files+=("$g")
    fi
  done < <(find "$d" -mindepth 1 -maxdepth 4 -name .git \( -type d -prune -o -type f \) -print0 2>/dev/null)
done
for g in "${git_files[@]}"; do
  mount_mode[$g]=ro
done
for p in "${git_dirs[@]}"; do
  if [[ -e "$p/commondir" ]]; then
    warn "$p has a commondir file, which redirects git to another directory: mounting the whole .git read-only"
    mount_mode[$p]=ro
    continue
  fi
  if ! mkdir -p "$p/hooks"; then
    warn "cannot create $p/hooks, leaving that git directory alone"
    continue
  fi
  mount_mode[$p/hooks]=ro
  [[ -f "$p/config" ]] && mount_mode[$p/config]=ro
  for f in "$p"/worktrees/*/commondir "$p"/worktrees/*/gitdir; do
    [[ -f "$f" && ! -L "$f" ]] && mount_mode[$f]=ro
  done
done

for f in "${path_args[@]}" "${mcp_args[@]}"; do
  [[ -n "$f" && "$f" != \{* ]] || continue
  [[ "$f" == /* ]] || f="$PWD/$f"
  [[ -e "$f" ]] || continue
  f="$(realpath "$f")"
  within "$f" "${rw_paths[@]}" /nix/store "${claude_home:-$HOME/.claude}" || mount_mode[$f]=ro
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

tool_versions_mounts=()
tv_dest="$HOME/.tool-versions"
if [[ -n "${mount_mode[$tv_dest]:-}" ]]; then
  : # podman refuses a second mount on the same destination
elif within "$HOME" "${rw_paths[@]}" "${!mount_mode[@]}"; then
  # the runtime would create an empty ~/.tool-versions on the host as the mountpoint (or fail on a read-only $HOME)
  log "no generated .tool-versions: $HOME is itself mounted"
else
  host_plugins=" "
  if [[ -s "$tv_dest" ]]; then
    cat "$tv_dest" > "$tmp_dir/.tool-versions"
    [[ -z "$(tail -c1 "$tv_dest")" ]] || echo >> "$tmp_dir/.tool-versions"
    host_plugins=" $(awk '/^[[:space:]]*#/ || NF == 0 { next } { printf "%s ", $1 }' "$tv_dest") "
  else
    : > "$tmp_dir/.tool-versions"
  fi
  added=0
  for plugin_dir in "$asdf_data_dir"/installs/*/; do
    [[ -d "$plugin_dir" ]] || continue
    plugin="$(basename "$plugin_dir")"
    [[ "$host_plugins" != *" $plugin "* ]] || continue
    versions="$(find "$plugin_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')"
    newest="$(grep -E '^[0-9]+(\.[0-9]+)*$' <<< "$versions" | sort -V | tail -n1 || true)"
    [[ -n "$newest" ]] || newest="$(sort -V <<< "$versions" | tail -n1)"
    if [[ -n "$newest" ]]; then
      printf '%s %s\n' "$plugin" "$newest" >> "$tmp_dir/.tool-versions"
      added=1
    fi
  done
  if (( added )) || [[ -s "$tv_dest" ]]; then
    tool_versions_mounts+=(-v "$tmp_dir/.tool-versions:$tv_dest:ro")
  fi
fi

# the host's nix.conf isn't visible in the container: CLI features come through NIX_CONFIG
nix_mounts=()
nix_env_flags=()
if [[ -d "$nix_daemon_socket_dir" ]]; then
  nix_bin=nix
  [[ -x "${DEV_TOOLS_BIN:-}/nix" ]] && nix_bin="$DEV_TOOLS_BIN/nix"
  nix_trusted=unknown
  for nix_cmd in "store info" "store ping"; do
    nix_rc=0
    # shellcheck disable=SC2086 # the two words of the subcommand
    nix_json="$(NIX_REMOTE=daemon NIX_CONFIG="experimental-features = nix-command flakes" \
      timeout 5 "$nix_bin" $nix_cmd --json 2>/dev/null)" || nix_rc=$?
    [[ "$nix_rc" == 124 ]] && break
    [[ "$nix_rc" != 0 ]] && continue
    nix_trusted="$(jq -r 'if .trusted == null then "unknown" elif (.trusted == 0 or .trusted == false) then "no" else "yes" end' <<< "$nix_json" 2>/dev/null)" || nix_trusted=unknown
    [[ "$nix_trusted" != unknown ]] && break
  done
  case "$nix_trusted" in
    yes) warn "not mounting the nix-daemon socket: you are a trusted nix user, which would be root on the host" ;;
    no) :  ;;
    *)
      if [[ "${SANDBOX_NIX_DAEMON:-}" == 1 ]]; then
        warn "nix-daemon: couldn't tell if you are a trusted nix user; mounting its socket because SANDBOX_NIX_DAEMON=1"
      else
        warn "not mounting the nix-daemon socket: couldn't tell if you are a trusted nix user; set SANDBOX_NIX_DAEMON=1 to mount it anyway"
      fi ;;
  esac
  if [[ "$nix_trusted" == no || ( "$nix_trusted" == unknown && "${SANDBOX_NIX_DAEMON:-}" == 1 ) ]]; then
    nix_mounts+=(-v "$nix_daemon_socket_dir:$nix_daemon_socket_dir")
    nix_env_flags+=(-e NIX_REMOTE=daemon -e "NIX_CONFIG=experimental-features = nix-command flakes")
  fi
fi

protect_mounts=()
agent_mounts=()
agent_env_flags=()
if [[ "$agent" == claude ]]; then
  for p in "$claude_home/skills" "$claude_home/agents" "$claude_home/CLAUDE.md"; do
    [[ -e "$p" ]] && protect_mounts+=(-v "$p:$p:ro")
  done
  # in Claude Code a deny wins over an allow at any settings level, so the managed allow alone can't lift a user deny
  user_settings="$claude_home/settings.json"
  if [[ -e "$user_settings" ]]; then
    if [[ -r "${MANAGED_SETTINGS:-}" ]] &&
      jq --slurpfile m "$MANAGED_SETTINGS" '
        ($m[0].permissions.allow // []) as $allow
        | if (.permissions.deny | type) == "array"
          then .permissions.deny |= map(select(. as $r | $allow | index($r) | not))
          else . end' "$user_settings" > "$tmp_dir/settings.json" 2>/dev/null; then
      protect_mounts+=(-v "$tmp_dir/settings.json:$user_settings:ro")
    else
      protect_mounts+=(-v "$user_settings:$user_settings:ro")
    fi
  fi
  agent_mounts=(
    -v "$claude_home:$claude_home:rw"
    -v "$claude_json:$claude_json:rw"
  )
  agent_env_flags=(-e CLAUDE_CODE_SANDBOXED=1)
  [[ -n "${AGENT_HOME:-}" ]] && agent_env_flags+=(-e "CLAUDE_CONFIG_DIR=$claude_home")
fi

if [[ "$agent" == kiro ]]; then
  if [[ -n "${AGENT_HOME:-}" ]]; then
    [[ "$AGENT_HOME" == /* ]] || { echo "$sandbox_name: AGENT_HOME must be absolute: $AGENT_HOME" >&2; exit 1; }
    kiro_home="$AGENT_HOME"
    kiro_state="$AGENT_HOME/.sandbox"
    log "profile ${AGENT_PROFILE:-?}: kiro's config in $kiro_home"
  else
    kiro_home="$HOME/.kiro"
    kiro_state="${XDG_DATA_HOME:-$HOME/.local/share}/kiro-sandbox"
  fi
  mkdir -p "$kiro_state/kiro" "$kiro_state/data"
  chmod 700 "$kiro_state"
  agent_mounts=(
    -v "$kiro_state/kiro:$HOME/.kiro:rw"
    -v "$kiro_state/data:$HOME/.local/share/kiro-cli:rw"
  )
  for d in agents skills steering hooks powers; do
    [[ -e "$kiro_home/$d" ]] && agent_mounts+=(-v "$kiro_home/$d:$HOME/.kiro/$d:ro")
  done
  kiro_settings="$tmp_dir/kiro-settings"
  mkdir -p "$kiro_settings"
  for f in "$kiro_home/settings"/*.json; do
    [[ -f "$f" && "$(basename "$f")" != mcp.json ]] && cp "$f" "$kiro_settings/"
  done
  host_mcp='{"mcpServers":{}}'
  if [[ -f "$kiro_home/settings/mcp.json" ]]; then
    host_mcp="$(jq -c '{mcpServers: (.mcpServers // {})}' "$kiro_home/settings/mcp.json" 2>/dev/null)" \
      || { warn "kiro: $kiro_home/settings/mcp.json isn't valid JSON, leaving its servers out"; host_mcp='{"mcpServers":{}}'; }
  fi
  printf '%s\n' "$host_mcp" "$proxy_mcp_config" "$extra_mcp_config" \
    | jq -s '{mcpServers: (map(select(. != null) | .mcpServers // {}) | add // {})}' > "$kiro_settings/mcp.json"
  log "kiro: MCP servers: $(jq -r '.mcpServers | keys | join(", ")' "$kiro_settings/mcp.json")"
  agent_mounts+=(-v "$kiro_settings:$HOME/.kiro/settings:rw")
fi

agent_args=("$@")
if [[ "$agent" == kiro && "${SANDBOX_TRUST_ALL:-1}" != 0 ]] && { (( $# == 0 )) || [[ "$1" == chat ]]; }; then
  trust_given=0
  for a in "${@:2}"; do
    [[ "$a" == -- ]] && break
    case "$a" in -a|--trust-all-tools|--trust-tools|--trust-tools=*) trust_given=1 ;; esac
  done
  if (( trust_given )); then
    log "kiro: trust as given on the command line"
  else
    agent_args=(chat --trust-all-tools "${@:2}")
    cli_json="$kiro_settings/cli.json"
    [[ -f "$cli_json" ]] || echo '{}' > "$cli_json"
    if jq '. + {"chat.disableTrustAllConfirmation": true}' "$cli_json" > "$cli_json.tmp" 2>/dev/null; then
      mv "$cli_json.tmp" "$cli_json"
    else
      rm -f "$cli_json.tmp"
      warn "kiro: ~/.kiro/settings/cli.json isn't valid JSON; kiro may ask to confirm trusting all tools"
    fi
    log "kiro: the chat trusts all tools (SANDBOX_TRUST_ALL=0 to be asked)"
  fi
fi

# no browser redirect reaches the container, so kiro logs in with the device flow
kiro_tty=0
[[ -t 0 && -t 1 ]] && kiro_tty=1
[[ "${SANDBOX_TEST:-}" == 1 && "${SANDBOX_TEST_TTY:-}" == 1 ]] && kiro_tty=1
if [[ "$agent" == kiro && "$kiro_tty" == 1 ]] && { (( $# == 0 )) || [[ "$1" == chat ]]; }; then
  # shellcheck disable=SC2016 # expanded by the container's bash
  kiro_login_first='"$1" whoami >/dev/null 2>&1 || {
  echo "kiro: this sandbox is not logged in to kiro-cli; logging in (the login is kept for later sessions)" >&2
  "$1" login --use-device-flow || exit
}
exec "$@"'
  agent_cmd=(bash -c "$kiro_login_first" kiro-login "${agent_cmd[@]}")
fi
for d in "$project_root" "${rw_dirs[@]}"; do
  [[ -d "$d/.obsidian" && -z "${mount_mode[$d/.obsidian]:-}" ]] && protect_mounts+=(-v "$d/.obsidian:$d/.obsidian:ro")
done

# podman sets TERM=xterm without COLORTERM, and Claude Code then drops to a reduced palette
env_pass=()
for v in TERM COLORTERM; do
  [[ -n "${!v:-}" ]] && env_pass+=(-e "$v=${!v}")
done

read -ra pass_globs <<< "${SANDBOX_CONFIG_PASS_ENV:-} ${SANDBOX_PASS_ENV:-}"
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

herdr_mounts=()
herdr_env_flags=()
if [[ "$agent" == kiro ]]; then
  herdr_tokens=(ctx_ok ctx_warn ctx_hot credits usage_error)
else
  herdr_tokens=(ctx_ok ctx_warn ctx_hot five_hour five_hour_warn five_hour_hot
    seven_day seven_day_warn seven_day_hot reset)
fi
herdr_report() {
  local fields=() args=() v i
  [[ -n "$1" && -f "$1" && ! -L "$1" ]] && mapfile -t -n "${#herdr_tokens[@]}" fields < "$1"
  for i in "${!herdr_tokens[@]}"; do
    v="${fields[i]:-}"
    v="${v//[[:cntrl:]]/}"
    args+=(--token "${herdr_tokens[i]}=${v:0:64}")
  done
  "$HERDR_BIN" pane report-metadata "$HERDR_PANE_ID" --source "$agent-usage" \
    --seq "$(date +%s%N)" "${args[@]}" >/dev/null 2>&1 || true
}

kiro_usage() {
  local dir="$1" index="$2" marker="$3" f n out p
  f="$(find "$dir" -mindepth 2 -maxdepth 2 -name messages.jsonl -type f -newer "$marker" -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -n 1 | cut -d' ' -f2-)" || f=
  if [[ -z "$f" ]]; then
    if [[ -f "$index" && "$index" -nt "$marker" ]] \
      && (( $(date +%s) - $(stat -c %Y "$index" 2>/dev/null || date +%s) > 30 )); then
      p="$(jq -rs '[.[] | select(.op? == "add") | .sessionPath?] | last // empty' "$index" 2>/dev/null)" || p=
      if [[ -z "$p" || ! -d "$(dirname "$dir")/$p" ]]; then
        echo "kiro usage: $index lists no session folder under $(dirname "$dir") (got '${p:0:100}')" >&2
        printf '\n\n\n\nusage ERROR\n'
      fi
    fi
    return 0
  fi
  n="$(wc -l < "$f" 2>/dev/null)" || n=0
  if ! out="$({ grep -F -e '"contextUsage"' -e '"usage_summary"' -- "$f" || true; } | jq -rs --argjson lines "$n" '
      def fmt: (. * 100 | round) / 100 | tostring;
      [.[] | .payload? // {} | select(.type? == "session_metadata" and .key? == "contextUsage")] as $meta
      | [.[] | .payload? // {} | select(.type? == "usage_summary")] as $sums
      | ($meta | last | .value.usagePercentage?) as $ctx
      | [$sums[] | .promptTurnSummaries[]? | select(.unit? == "credit") | .usage] as $credits
      | if ($meta | length) > 0 and ($ctx | type) != "number" then "contextUsage has no numeric usagePercentage"
        elif ($sums | length) > 0 and ($credits | length) == 0 then "usage_summary has no credit usage"
        elif ($credits | any(type != "number")) then "a credit usage is not a number"
        elif ($meta | length) == 0 and $lines > 100 then "no contextUsage record in \($lines) lines"
        else
          (if $ctx == null then ["", "", ""]
           else ("ctx \($ctx | round)%") as $s
             | if $ctx >= 80 then ["", "", $s] elif $ctx >= 60 then ["", $s, ""] else [$s, "", ""] end
           end)
          + [if ($credits | length) == 0 then "" else "\($credits | add | fmt) credits" end, ""]
          | map(if . == "" then "-" else . end) | @tsv
        end' 2>&1)"; then
    out="kiro's records aren't JSON: ${out:0:200}"
  fi
  if [[ "$out" == *$'\t'* ]]; then
    tr '\t' '\n' <<< "$out" | sed 's/^-$//'
  else
    echo "kiro usage: $f: $out" >&2
    printf '\n\n\n\nusage ERROR\n'
  fi
}

if [[ "$agent" == kiro && "${HERDR_ENV:-}" == 1 && -n "${HERDR_PANE_ID:-}" && -n "${HERDR_BIN:-}" ]]; then
  herdr_dir="$(mktemp -d)"
  touch "$herdr_dir/launched"
  cwd_hash="$(printf '%s' "$PWD" | sha256sum | cut -c1-16)"
  kiro_sessions="$kiro_state/kiro/sessions/$cwd_hash"
  kiro_index="$kiro_state/kiro/session-index/$cwd_hash.jsonl"
  (
    last='' last_err=''
    while sleep 2; do
      kiro_usage "$kiro_sessions" "$kiro_index" "$herdr_dir/launched" > "$herdr_dir/usage" 2> "$herdr_dir/error"
      cur="$(cat "$herdr_dir/usage")"
      if [[ "$cur" != "$last" ]]; then
        herdr_report "$herdr_dir/usage"
        last="$cur"
      fi
      err="$(cat "$herdr_dir/error")"
      if [[ -n "$err" && "$err" != "$last_err" ]]; then
        log_line "warning: $err (kiro's session format may have changed)" >/dev/null
      fi
      last_err="$err"
    done
  ) &
  herdr_watch_pid=$!
fi
if [[ "$agent" == claude && "${HERDR_ENV:-}" == 1 && -n "${HERDR_PANE_ID:-}" && -n "${HERDR_BIN:-}" ]]; then
  herdr_dir="$(mktemp -d)"
  herdr_mounts=(-v "$herdr_dir:$herdr_dir")
  herdr_env_flags=(-e "SANDBOX_HERDR_DIR=$herdr_dir")
  (
    last=
    while sleep 2; do
      cur=
      [[ -f "$herdr_dir/usage" && ! -L "$herdr_dir/usage" ]] \
        && { IFS= read -r -d '' cur < "$herdr_dir/usage" || true; }
      if [[ "$cur" != "$last" ]]; then
        herdr_report "$herdr_dir/usage"
        last="$cur"
      fi
    done
  ) &
  herdr_watch_pid=$!
fi

review_mounts=()
review_env_flags=()
if [[ "$agent" == claude && -n "${REVIEW_BROKER:-}" && -n "${REVIEW_BROKER_KIRO:-}" \
      && -n "${REVIEW_BROKER_MODELS:-}" && -f "$project_root/workspace.json" ]]; then
  review_broker_dir="$(mktemp -d)"
  review_args=(serve --socket "$review_broker_dir/review.sock" --workspace "$project_root"
    --kiro "$REVIEW_BROKER_KIRO" --effort "${REVIEW_BROKER_EFFORT:-high}"
    --max-parallel "${REVIEW_BROKER_MAX_PARALLEL:-2}" --timeout "${REVIEW_BROKER_TIMEOUT:-45m}")
  IFS=':' read -ra review_models <<< "$REVIEW_BROKER_MODELS"
  for m in "${review_models[@]}"; do [[ -n "$m" ]] && review_args+=(--model "$m"); done
  for d in "${rw_dirs[@]}"; do review_args+=(--add-dir "$d"); done
  log "starting review-broker (models: ${REVIEW_BROKER_MODELS//:/, })"
  "$REVIEW_BROKER" "${review_args[@]}" 2>> "$launch_log" &
  review_broker_pid=$!
  for _ in $(seq 1 50); do
    [[ -S "$review_broker_dir/review.sock" ]] && break
    sleep 0.1
  done
  if [[ -S "$review_broker_dir/review.sock" ]]; then
    review_mounts+=(-v "$review_broker_dir/review.sock:$review_broker_dir/review.sock")
    review_env_flags+=(-e "TIX_REVIEW_BROKER_SOCKET=$review_broker_dir/review.sock")
  else
    warn "review-broker didn't start (see $launch_log): deep reviews stay on Claude models"
  fi
fi

# podman -t fails without a terminal (headless claude -p)
tty_flags=(-i)
[[ -t 0 && -t 1 ]] && tty_flags=(-it)

git_config=(core.excludesFile "$GIT_GLOBAL_IGNORE" log.showSignature false)
[[ "$git_signing" == 1 && "${SANDBOX_GIT_AUTOSIGN:-1}" != 0 ]] || git_config+=(commit.gpgSign false tag.gpgSign false)
git_config+=(filter.lfs.clean "git-lfs clean -- %f" filter.lfs.smudge "git-lfs smudge -- %f" filter.lfs.process "git-lfs filter-process" filter.lfs.required true lfs.sshtransfer never)
git_config_flags=(-e "GIT_CONFIG_COUNT=$(( ${#git_config[@]} / 2 ))")
for (( i = 0; i < ${#git_config[@]}; i += 2 )); do
  git_config_flags+=(-e "GIT_CONFIG_KEY_$(( i / 2 ))=${git_config[i]}" -e "GIT_CONFIG_VALUE_$(( i / 2 ))=${git_config[i + 1]}")
done
log "starting $agent in $pod_name-$agent (pulls its image on first use)"
claude_started=1
managed_mounts=()
if [[ "$agent" != claude ]]; then
  :
elif [[ -n "${MANAGED_SETTINGS:-}" ]]; then
  managed_mounts=(-v "$MANAGED_SETTINGS:/etc/claude-code/managed-settings.json:ro")
else
  echo "claude-sandbox: MANAGED_SETTINGS is unset; kill and delete commands keep Claude's default permission checks" >&2
fi

# tools that ignore SSL_CERT_FILE: Dart (flutter pub get) reads only /etc/pki/tls/certs/ca-bundle.crt
# or a hashed /etc/ssl/certs; Debian-built tools expect /etc/ssl/certs/ca-certificates.crt
cacert_mounts=(
  -v "$CACERT_BUNDLE:/etc/pki/tls/certs/ca-bundle.crt:ro"
  -v "$CACERT_BUNDLE:/etc/ssl/certs/ca-certificates.crt:ro"
)

# podman's defaults: UTC without --tz=local; an overlay upperdir can't be on the container's
# overlayfs root, so nested podman's storage and its build temp dir (/var/tmp) are volumes;
# without --init the agent is PID 1, so its tools' orphans go unreaped and servers watching
# their parent see PID 1 instead
systemd-run --user --scope --quiet --collect --slice=aisandbox.slice -- \
podman run --rm "${tty_flags[@]}" \
  --init \
  --name "$pod_name-$agent" \
  --pod "$pod_name" \
  "${name_labels[@]}" \
  --label "$sandbox_name.role=$agent" \
  --privileged \
  --pull=missing \
  --tz=local \
  -v /nix/store:/nix/store:ro \
  -v /var/lib/containers \
  -v /var/tmp \
  -v "$project_root:$project_root:$project_mode" \
  "${dir_mounts[@]}" \
  -w "$PWD" \
  -v "$asdf_data_dir:$asdf_data_dir:ro" \
  "${agent_mounts[@]}" \
  "${managed_mounts[@]}" \
  "${cacert_mounts[@]}" \
  "${mounts[@]}" \
  "${tool_versions_mounts[@]}" \
  "${nix_mounts[@]}" \
  "${protect_mounts[@]}" \
  "${dbus_mounts[@]}" \
  "${git_mounts[@]}" \
  "${review_mounts[@]}" \
  "${herdr_mounts[@]}" \
  -e HOME="$HOME" \
  -e ASDF_DATA_DIR="$asdf_data_dir" \
  -e SSL_CERT_FILE="$CACERT_BUNDLE" \
  -e GIT_CONFIG_GLOBAL="$GIT_GLOBAL_CONFIG" \
  "${git_config_flags[@]}" \
  "${git_env_flags[@]}" \
  "${review_env_flags[@]}" \
  -e PATH="$asdf_data_dir/shims:$ASDF_VM_BIN:$NESTED_PODMAN_ENV_BIN:$DEV_TOOLS_BIN:$agent_out/bin:/usr/bin:/bin" \
  "${registry_env_flags[@]}" \
  "${dbus_env_flags[@]}" \
  "${nix_env_flags[@]}" \
  "${env_pass[@]}" \
  "${herdr_env_flags[@]}" \
  "${agent_env_flags[@]}" \
  "$SANDBOX_IMAGE" \
  "$NESTED_PODMAN_SETUP" "${agent_cmd[@]}" "${mcp_flags[@]}" "${agent_args[@]}"
code=$?
exit "$code"
