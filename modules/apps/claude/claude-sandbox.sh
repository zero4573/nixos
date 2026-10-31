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
#   CLAUDE_SANDBOX_PASS_ENV     space-separated globs of host environment
#                               variables to pass in, e.g. "CLAUDE_TICKETS_*"
#   CLAUDE_SANDBOX_RO_PATHS     colon-separated host paths to mount read-only
#                               in every session (~ and $HOME expanded)
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
  * the CA bundle (CACERT_BUNDLE) read-only at /etc/pki/tls/certs/ca-bundle.crt
    and /etc/ssl/certs/ca-certificates.crt: the image has none, and tools that
    ignore SSL_CERT_FILE (Dart/pub reads only these locations) need one there
  * container-only managed settings at /etc/claude-code/managed-settings.json
    that allow kill, pkill, killall, rm, rmdir, unlink and git push, and deny
    force pushes and deletes; the user settings' denies of the allowed rules
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
    CLAUDE_SANDBOX_NIX_DAEMON=1 mounts it anyway in that case (a known-
    trusted user never gets it)
  * git over SSH through git-ssh-broker, started on the host for the
    session: fetch and push to GitHub/Bitbucket with your host ssh setup,
    but never a force push, a branch/tag delete or a tag move (do those on
    the host); commits are signed through its git-signatures-only agent
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

Sandbox settings (environment):
  CLAUDE_SANDBOX_PORTS=3000,5173   publish ports on the same host ports
  CLAUDE_SANDBOX_NAME=<label>      pod claude-sandbox-<label>
  CLAUDE_SANDBOX_QUIET=1           only print warnings while launching
  CLAUDE_SANDBOX_PASS_ENV="A_* B"  host variables to pass in (name globs)
  CLAUDE_SANDBOX_RO_PATHS=/a:~/b   host paths mounted read-only at the same
                                   path in every session (programs.
                                   claudeSandbox.readOnlyPaths); ~ and $HOME
                                   are expanded, a missing path is skipped,
                                   and one inside a read-write directory
                                   stays read-only; one containing the
                                   project or an --add-dir is skipped with
                                   a warning. Set in the host env, it
                                   replaces the configured list

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
# session starts on the updated tree
if git -C "$project_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "updating the git checkout (git fetch, at most 30s)"
  "$CLAUDE_GIT_UPDATE" "$project_root"
fi
asdf_data_dir="$HOME/.asdf"
# Where the host's nix-daemon listens (the launcher sets this to the same
# value; it is an override for the script's test only, not a user setting)
nix_daemon_socket_dir="$(realpath -m -- "${NIX_DAEMON_SOCKET_DIR:-/nix/var/nix/daemon-socket}")"
if [[ "$nix_daemon_socket_dir" != /nix/var/nix/* && "${CLAUDE_SANDBOX_TEST:-}" != 1 ]]; then
  # the directory is bind-mounted read-write: don't take an arbitrary one
  warn "NIX_DAEMON_SOCKET_DIR=$nix_daemon_socket_dir is outside /nix/var/nix/ (only the test may set it): ignoring it"
  nix_daemon_socket_dir=/nix/var/nix/daemon-socket
fi

# Consolidated exit cleanup
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
  if [[ -n "${herdr_watch_pid:-}" ]]; then
    kill "$herdr_watch_pid" 2>/dev/null || true
    herdr_report ""  # clears the pane's usage rows
  fi
  [[ -n "${pod_name:-}" ]] && podman pod rm -f -t 5 "$pod_name" >/dev/null 2>&1 || true
  [[ -n "${tmp_dir:-}" && -d "$tmp_dir" ]] && rm -rf "$tmp_dir"
  [[ -n "${dbus_proxy_dir:-}" && -d "$dbus_proxy_dir" ]] && rm -rf "$dbus_proxy_dir"
  [[ -n "${git_broker_dir:-}" && -d "$git_broker_dir" ]] && rm -rf "$git_broker_dir"
  [[ -n "${herdr_dir:-}" && -d "$herdr_dir" ]] && rm -rf "$herdr_dir"
  return 0  # under set -e, a false last test above would become the exit status
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

# Git over SSH and commit signing: git-ssh-broker (modules/apps/git-ssh-broker)
# runs here on the host for this session and its sockets are mounted in. The
# git socket carries git's transport commands to GitHub/Bitbucket through the
# host's ssh, refusing force pushes and branch/tag deletes; the agent socket
# signs git signatures only, with the signing keys (CLAUDE_SANDBOX_SIGNING_KEYS,
# public halves mounted read-only), through the host's agent (SSH_AUTH_SOCK,
# else GIT_SSH_BROKER_UPSTREAM_AGENT). No SSH key or agent of the host is
# ever reachable from the sandbox itself. Without signing keys or an agent,
# sessions still push, and commit unsigned.
git_mounts=()
git_env_flags=()
git_signing=0
if [[ -n "${GIT_SSH_BROKER:-}" ]]; then
  git_broker_dir="$(mktemp -d)"
  broker_args=(serve --git-socket "$git_broker_dir/git.sock")
  [[ -n "${GIT_SSH_BROKER_SSH:-}" ]] && broker_args+=(--ssh "$GIT_SSH_BROKER_SSH")
  upstream_agent="${SSH_AUTH_SOCK:-${GIT_SSH_BROKER_UPSTREAM_AGENT:-}}"
  upstream_agent="${upstream_agent/#\~/$HOME}"
  signing_keys=()
  IFS=':' read -ra configured_keys <<< "${CLAUDE_SANDBOX_SIGNING_KEYS:-}"
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
      # git log --show-signature / %G? verify against it (modules/apps/git.nix)
      [[ -f "$HOME/.ssh/allowed_signers" ]] && git_mounts+=(-v "$HOME/.ssh/allowed_signers:$HOME/.ssh/allowed_signers:ro")
    fi
  else
    warn "git-ssh-broker didn't come up: no git over SSH in this session"
    kill "$git_broker_pid" 2>/dev/null || true
    git_broker_pid=""
  fi
fi

# Claude runs in a pod of its own; ports and networks are set on the pod.
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
# reboot) are left behind. Remove the ones whose claude container is gone and
# that are over 10 minutes old (a new session's pod has no claude container
# until the launch gets that far).
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

# Stdio MCP servers every session gets (programs.claudeSandbox.extraMcpServers),
# from a config file in the store
extra_mcp_config=""
if [[ -n "${EXTRA_MCP_CONFIG:-}" ]]; then
  extra_mcp_config="$(cat "$EXTRA_MCP_CONFIG")"
  log "extra MCP servers: $(jq -r '.mcpServers | keys | join(", ")' <<< "$extra_mcp_config" 2>/dev/null)"
fi

# All MCP servers go into one file passed as --mcp-config=<file>: the flag
# is variadic, so a separate value would swallow a following positional
# prompt as another config file. claude merges it with any --mcp-config of
# the caller.
mcp_flags=()
if [[ -n "$proxy_mcp_config$extra_mcp_config" ]]; then
  printf '%s\n' "$proxy_mcp_config" "$extra_mcp_config" \
    | jq -s '{mcpServers: (map(select(. != null) | .mcpServers) | add)}' > "$tmp_dir/mcp.json"
  mounts+=(-v "$tmp_dir/mcp.json:$tmp_dir/mcp.json:ro")
  mcp_flags+=("--mcp-config=$tmp_dir/mcp.json")
fi
# The language servers' plugin (programs.claudeSandbox.lspServers), a store
# path the container reaches through the /nix/store mount
if [[ -n "${CLAUDE_LSP_PLUGIN:-}" ]]; then
  mcp_flags+=(--plugin-dir "$CLAUDE_LSP_PLUGIN")
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
    # dir/** or dir/* is dir (one suffix only: a/*/** is every a/<x>)
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
      # The part before the first wildcard is a directory this rule covers
      # some of the clones of (a/*/*/* is the clones in a/): it goes
      # read-only too, so a session can't create files at the levels in
      # between or write into a clone made after launch. Clones that
      # already exist are mounted below it as before (those with their own
      # read-write .git get it back, more specific).
      # Only when the first wildcard is a whole path component (* or **):
      # .env* or src/*.key has a wildcard inside a name, and its prefix is
      # the project or a directory of ordinary files. Never the project.
      head="${rule%%[*?[]*}"
      tail="${rule#"$head"}"
      comp="${tail%%/*}"
      prefix="${head%/*}"
      if [[ "$head" == */ && ( "$comp" == '*' || "$comp" == '**' ) \
        && -n "$prefix" && -d "$prefix" && "$prefix" != "$(realpath -m "$project_root")" ]]; then
        ro_paths+=("$prefix")
      fi
      # compgen -G takes the pattern as one word: a clone path with spaces
      # stays whole. A symlink at a matched depth is skipped: mounting it
      # would mount its target's path.
      while IFS= read -r m; do
        [[ -n "$m" && -e "$m" && ! -L "$m" ]] && ro_paths+=("$m")
      done < <(compgen -G "$rule" || true)
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

# Paths every session may read but not change (CLAUDE_SANDBOX_RO_PATHS, from
# programs.claudeSandbox.readOnlyPaths), e.g. a model cache: mounted read-only
# at the same path, also when inside a read-write directory; missing ones are
# skipped. One equal to or containing a read-write directory (the project
# included) is skipped with a warning: these are shared caches and never take
# write access from the project or an --add-dir (W2-nixos-C01); a read-only
# project comes only from Claude's deny rules, above. Only ~ and $HOME are
# expanded, not ~user (W1-nixos-C02)
IFS=: read -ra extra_ro <<< "${CLAUDE_SANDBOX_RO_PATHS:-}"
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
  skip=
  for r in "${rw_paths[@]}"; do
    if [[ "$r" == "$p" || "$r" == "${p%/}"/* ]]; then skip=$r; break; fi
  done
  if [[ -n "$skip" ]]; then
    warn "read-only path $p contains the read-write directory $skip, not mounting it read-only"
    continue
  fi
  mount_mode[$p]=ro
done

# A git directory given read-write on its own (e.g. a main clone's .git, so
# the session can add worktrees to it) keeps its config and hooks read-only:
# from there a session could run code on the host the next time git runs in
# that clone. (hooks/ is created first, or the session could create it.)
# The same goes for every clone that already exists under a read-write
# directory (a ticket session gets the repo directory as one writable mount):
# <dir>/<provider>/<owner>/<repo>/.git, found up to four levels down, not
# following symlinks and not looking inside read-only mounts, and not below
# $HOME itself when that is the scan root. A worktree's .git is a file that
# points into its main clone: every one found is read-only, and so are the
# commondir and gitdir files of the worktrees a clone already has
# (.git/worktrees/ itself stays writable, so `git worktree add` still
# works). A main clone with a .git/commondir is redirected already: it gets
# a warning and its whole .git read-only. Without these, a session could
# repoint git at a config of its own.
# Residual risk: a clone made during the session is not covered until the
# next launch makes its files read-only. ct's host git disables hooks,
# fsmonitor and external diff and checks the pointer files, but other config
# keys (filters, sshCommand, credential helpers) and the user's own git in
# such a clone are not covered.
# Side effect: a plain `git branch -d` in such a clone warns "could not write
# config file ... Device or resource busy" (the branch.<name> config section
# can't be removed) but still deletes the ref; ticket tooling uses
# `git update-ref -d` after a merge check.
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

# asdf's shims read $HOME/.tool-versions when no nearer file sets a tool, so
# python3, go and gofmt would fail in a directory without one. A generated
# file is mounted read-only at the same place: the host's own lines as they
# are (if it has a non-empty file), plus the newest installed version of
# every plugin under asdf's installs/ that the host file doesn't name
# (numeric sort per dot part), so a host file that lacks python still gives
# python3 in any directory. A workspace's own .tool-versions
# (tool-versions-v1, written by ct) is nearer and wins.
tool_versions_mounts=()
tv_dest="$HOME/.tool-versions"
if [[ -n "${mount_mode[$tv_dest]:-}" ]]; then
  : # a read-only path already mounts it: a second mount would clash
elif within "$HOME" "${rw_paths[@]}" "${!mount_mode[@]}"; then
  # $HOME is mounted: the runtime would create an empty ~/.tool-versions on
  # the host as the mountpoint (or fail when $HOME is read-only)
  log "no generated .tool-versions: $HOME is itself mounted"
else
  # The host's lines first, untouched; the plugins it names (first field of
  # a non-comment line) are not added again
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
    # Numeric names (3.12.1) sort by dot part with sort -V; names like
    # 3.14-dev or ref-abc only count when there is no numeric one
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

# The host's nix-daemon, so `nix eval` and `nix flake check --no-build` work
# in the session (/nix/store is already mounted, read-only). Only the
# socket's directory is mounted, and only when the daemon is there. The
# trade-off: the session can talk to the daemon as the invoking user, which
# lets it evaluate, fetch and build on the host (builds run outside the
# sandbox); it can't write the store directly, but only while the invoking
# user is NOT in nix.settings.trusted-users: a trusted client can set
# `sandbox = false`, extra sandbox paths and import unsigned paths, which is
# root on the host. So the daemon is asked first (`nix store info --json`,
# field `trusted`, with the launcher's own nix) and the mount is skipped when
# the user is trusted, and when it can't be told (fail closed, with a warning);
# CLAUDE_SANDBOX_NIX_DAEMON=1 forces the mount for the unknown case.
# The host's nix.conf isn't visible in the container, so the CLI features
# come through NIX_CONFIG.
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
    # a hung daemon: don't wait for the second probe too
    [[ "$nix_rc" == 124 ]] && break
    [[ "$nix_rc" != 0 ]] && continue
    nix_trusted="$(jq -r 'if .trusted == null then "unknown" elif (.trusted == 0 or .trusted == false) then "no" else "yes" end' <<< "$nix_json" 2>/dev/null)" || nix_trusted=unknown
    [[ "$nix_trusted" != unknown ]] && break
  done
  case "$nix_trusted" in
    yes) warn "not mounting the nix-daemon socket: you are a trusted nix user, which would be root on the host" ;;
    no) :  ;;
    *)
      if [[ "${CLAUDE_SANDBOX_NIX_DAEMON:-}" == 1 ]]; then
        warn "nix-daemon: couldn't tell if you are a trusted nix user; mounting its socket because CLAUDE_SANDBOX_NIX_DAEMON=1"
      else
        warn "not mounting the nix-daemon socket: couldn't tell if you are a trusted nix user; set CLAUDE_SANDBOX_NIX_DAEMON=1 to mount it anyway"
      fi ;;
  esac
  if [[ "$nix_trusted" == no || ( "$nix_trusted" == unknown && "${CLAUDE_SANDBOX_NIX_DAEMON:-}" == 1 ) ]]; then
    nix_mounts+=(-v "$nix_daemon_socket_dir:$nix_daemon_socket_dir")
    nix_env_flags+=(-e NIX_REMOTE=daemon -e "NIX_CONFIG=experimental-features = nix-command flakes")
  fi
fi

# Kept read-only on top of the writable mounts:
#  * the host-side Claude config (settings with its hooks, skills, agents),
#    or a session could plant a hook that runs unsandboxed on the host
#  * the .obsidian folder of any Obsidian vault mounted writable: community
#    plugins installed there would run in Obsidian on the host
protect_mounts=()
for p in "$HOME/.claude/skills" "$HOME/.claude/agents" "$HOME/.claude/CLAUDE.md"; do
  [[ -e "$p" ]] && protect_mounts+=(-v "$p:$p:ro")
done
# The user settings, minus each deny rule the container's managed settings
# allow (e.g. rm -rf, denied on the host): a deny wins over an allow at any
# level, so the managed allow alone wouldn't lift it. Unfiltered when there
# are no managed settings to read.
user_settings="$HOME/.claude/settings.json"
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
for d in "$project_root" "${rw_dirs[@]}"; do
  [[ -d "$d/.obsidian" && -z "${mount_mode[$d/.obsidian]:-}" ]] && protect_mounts+=(-v "$d/.obsidian:$d/.obsidian:ro")
done

# The terminal's own TERM and COLORTERM: podman's default is TERM=xterm
# with no COLORTERM, and Claude Code then drops to a reduced palette where
# its highlights (selection, diffs) barely show
env_pass=()
for v in TERM COLORTERM; do
  [[ -n "${!v:-}" ]] && env_pass+=(-e "$v=${!v}")
done

# Host variables passed in: CLAUDE_SANDBOX_PASS_ENV, space-separated name
# globs (e.g. set by the system config for tools used inside the sandbox)
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

# herdr's usage rows (modules/apps/herdr): the status line script can't
# reach herdr from the container, and herdr's socket would let the sandbox
# drive every pane, so it writes its fields, one per line, to a file in a
# directory mounted from the host (CLAUDE_SANDBOX_HERDR_DIR), and this
# launcher, which runs in the herdr pane, reports them. Values are cut to
# 64 characters with control characters removed; a symlink is ignored.
herdr_mounts=()
herdr_env_flags=()
herdr_tokens=(ctx_ok ctx_warn ctx_hot five_hour five_hour_warn five_hour_hot
  seven_day seven_day_warn seven_day_hot reset)
# herdr_report <file>: the file's lines as the tokens, in order; "" clears them
herdr_report() {
  local fields=() args=() v i
  [[ -n "$1" && -f "$1" && ! -L "$1" ]] && mapfile -t -n "${#herdr_tokens[@]}" fields < "$1"
  for i in "${!herdr_tokens[@]}"; do
    v="${fields[i]:-}"
    v="${v//[[:cntrl:]]/}"
    args+=(--token "${herdr_tokens[i]}=${v:0:64}")
  done
  "$HERDR_BIN" pane report-metadata "$HERDR_PANE_ID" --source claude-usage \
    --seq "$(date +%s%N)" "${args[@]}" >/dev/null 2>&1 || true
}
if [[ "${HERDR_ENV:-}" == 1 && -n "${HERDR_PANE_ID:-}" && -n "${HERDR_BIN:-}" ]]; then
  herdr_dir="$(mktemp -d)"
  herdr_mounts=(-v "$herdr_dir:$herdr_dir")
  herdr_env_flags=(-e "CLAUDE_SANDBOX_HERDR_DIR=$herdr_dir")
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

# Only ask podman for a TTY when there is one, so headless runs (claude -p
# from a script) work too
tty_flags=(-i)
[[ -t 0 && -t 1 ]] && tty_flags=(-it)

# Git: the host's global config (a /nix/store file, with its per-remote
# identity includes), so commits made here carry the right author and are
# signed through git-ssh-broker's agent. Without that agent, signing is
# turned off, so commits still work (unsigned).
git_config=(core.excludesFile "$GIT_GLOBAL_IGNORE" log.showSignature false)
[[ "$git_signing" == 1 ]] || git_config+=(commit.gpgSign false tag.gpgSign false)
git_config_flags=(-e "GIT_CONFIG_COUNT=$(( ${#git_config[@]} / 2 ))")
for (( i = 0; i < ${#git_config[@]}; i += 2 )); do
  git_config_flags+=(-e "GIT_CONFIG_KEY_$(( i / 2 ))=${git_config[i]}" -e "GIT_CONFIG_VALUE_$(( i / 2 ))=${git_config[i + 1]}")
done
#
# Nested podman's storage gets an anonymous volume (removed with the
# container): on the container's own overlayfs root, overlay mounts in it
# (e.g. podman run --rootfs <dir>:O) fail, an overlay upperdir can't be on
# overlayfs.
#
# --init puts catatonit at PID 1, not claude: it reaps the orphans claude's
# tools leave behind (git's helpers pile up as zombies until the pids limit
# is hit otherwise), and stdio MCP and language servers get claude as a
# real parent: one that watches its parent to know when to exit can't with
# PID 1 as its parent.
log "starting claude in $pod_name-claude (pulls its image on first use)"
claude_started=1
# Container-only managed settings (the kill and delete allow rules), set
# by the Nix wrapper; without it the session just lacks those rules
managed_mounts=()
if [[ -n "${MANAGED_SETTINGS:-}" ]]; then
  managed_mounts=(-v "$MANAGED_SETTINGS:/etc/claude-code/managed-settings.json:ro")
else
  echo "claude-sandbox: MANAGED_SETTINGS is unset; kill and delete commands keep Claude's default permission checks" >&2
fi

# The CA bundle where tools that ignore SSL_CERT_FILE look for one: Dart
# (flutter pub get) reads only /etc/pki/tls/certs/ca-bundle.crt or a hashed
# /etc/ssl/certs; Debian-built tools expect /etc/ssl/certs/ca-certificates.crt
cacert_mounts=(
  -v "$CACERT_BUNDLE:/etc/pki/tls/certs/ca-bundle.crt:ro"
  -v "$CACERT_BUNDLE:/etc/ssl/certs/ca-certificates.crt:ro"
)

# --tz=local copies the host's /etc/localtime in, so times Claude shows
# (/usage resets, timestamps) are the system's rather than UTC
systemd-run --user --scope --quiet --collect --slice=aisandbox.slice -- \
podman run --rm "${tty_flags[@]}" \
  --init \
  --name "$pod_name-claude" \
  --pod "$pod_name" \
  "${name_labels[@]}" \
  --label claude-sandbox.role=claude \
  --privileged \
  --pull=missing \
  --tz=local \
  -v /nix/store:/nix/store:ro \
  -v /var/lib/containers \
  -v "$project_root:$project_root:$project_mode" \
  "${dir_mounts[@]}" \
  -w "$PWD" \
  -v "$asdf_data_dir:$asdf_data_dir:ro" \
  -v "$HOME/.claude:$HOME/.claude:rw" \
  -v "$HOME/.claude.json:$HOME/.claude.json:rw" \
  "${managed_mounts[@]}" \
  "${cacert_mounts[@]}" \
  "${mounts[@]}" \
  "${tool_versions_mounts[@]}" \
  "${nix_mounts[@]}" \
  "${protect_mounts[@]}" \
  "${dbus_mounts[@]}" \
  "${git_mounts[@]}" \
  "${herdr_mounts[@]}" \
  -e HOME="$HOME" \
  -e ASDF_DATA_DIR="$asdf_data_dir" \
  -e SSL_CERT_FILE="$CACERT_BUNDLE" \
  -e GIT_CONFIG_GLOBAL="$GIT_GLOBAL_CONFIG" \
  "${git_config_flags[@]}" \
  "${git_env_flags[@]}" \
  -e PATH="$asdf_data_dir/shims:$ASDF_VM_BIN:$NESTED_PODMAN_ENV_BIN:$DEV_TOOLS_BIN:$claude_out/bin:/usr/bin:/bin" \
  "${registry_env_flags[@]}" \
  "${dbus_env_flags[@]}" \
  "${nix_env_flags[@]}" \
  "${env_pass[@]}" \
  "${herdr_env_flags[@]}" \
  "$CLAUDE_SANDBOX_IMAGE" \
  "$NESTED_PODMAN_SETUP" "$claude_out/bin/claude" "${mcp_flags[@]}" "$@"
code=$?
exit "$code"
