#!/usr/bin/env bash
# Test of claude-sandbox.sh: runs it with stubs for everything it launches
# (podman, systemd-run, ...) first on PATH, in a throwaway HOME and project,
# and asserts the -v mount list handed to `podman run`. Needs bash, jq, git
# and coreutils. Usage: claude-sandbox-test.sh [path to claude-sandbox.sh]
# (default: the sibling script). Also a flake check, claude-sandbox-check.nix.
set -euo pipefail
# The sandbox settings of the shell running the test never reach a case
while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep -E '^(SANDBOX|CLAUDE_SANDBOX|KIRO_SANDBOX)_' || true)
# Nor does an agent session's own profile (run from claude/kiro, these point
# at the real profile home), or the cases would use it instead of their HOME
unset AGENT AGENT_HOME AGENT_PROFILE KIRO_HOME CLAUDE_CONFIG_DIR XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME

script="$(realpath "${1:-$(dirname "${BASH_SOURCE[0]}")/claude-sandbox.sh}")"
root="$(realpath "$(mktemp -d)")"
trap 'rm -rf "$root"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
ok() { echo "ok: $*"; }

# Stubs: podman records the arguments of `run` (one per line) and copies the
# source of any mount onto ~/.tool-versions and ~/.claude/settings.json; everything else succeeds, except
# `pod exists` (no name clashes) and `inspect`. nix answers `store info` with
# "trusted" from STUB_NIX_TRUSTED (0, 1, none = field absent, fail = error).
# The shebang is the running bash, not /usr/bin/env: the Nix build sandbox has
# no /usr/bin/env.
stubs="$root/stubs"
mkdir -p "$stubs"
stub() {  # stub <name>: the body comes on stdin
  { printf '#!%s\n' "$BASH"; cat; } > "$stubs/$1"
}
stub podman <<'STUB'
if [[ "$1" == pod && "$2" == exists ]]; then exit 1; fi
if [[ "$1" == inspect ]]; then exit 1; fi
if [[ "$1" == run ]]; then
  printf '%s\n' "$@" > "$STUB_OUT/run.args"
  # STUB_USAGE: a status line's usage file, written as the container would,
  # then left for the launcher's relay (which polls every 2s) to report
  if [[ -n "${STUB_USAGE:-}" ]]; then
    dir="$(printf '%s\n' "$@" | sed -n 's/^SANDBOX_HERDR_DIR=//p')"
    printf '%b' "$STUB_USAGE" > "$dir/usage"
    sleep 3
  fi
  # STUB_KIRO_SESSION: lines kiro-cli would write to its session file
  # (STUB_KIRO_FILE), then left for the launcher's usage relay to read
  if [[ -n "${STUB_KIRO_FILE:-}" ]]; then
    mkdir -p "$(dirname "$STUB_KIRO_FILE")"
    printf '%b' "${STUB_KIRO_SESSION:-}" > "$STUB_KIRO_FILE"
    sleep "${STUB_KIRO_WAIT:-3}"
  fi
  prev=
  for a in "$@"; do
    if [[ "$prev" == -v && "$a" == *:*/.tool-versions:ro ]]; then
      cp "${a%%:*}" "$STUB_OUT/tool-versions.copy"
    fi
    if [[ "$prev" == -v && "$a" == *:*/.claude/settings.json:ro ]]; then
      cp "${a%%:*}" "$STUB_OUT/settings.copy"
    fi
    if [[ "$prev" == -v && "$a" == *:*/.kiro/settings:rw ]]; then
      cp -r "${a%%:*}" "$STUB_OUT/kiro-settings.copy"
    fi
    prev="$a"
  done
fi
exit 0
STUB
stub systemd-run <<'STUB'
while [[ "$1" != -- ]]; do shift; done
shift
exec "$@"
STUB
stub nix <<'STUB'
case "${STUB_NIX_TRUSTED:-0}" in
  fail) exit 1 ;;
  none) echo '{}' ;;
  *) echo "{\"trusted\":$STUB_NIX_TRUSTED}" ;;
esac
STUB
echo 'exit 0' | stub xdg-dbus-proxy
echo 'exit 1' | stub sandbox-proxy
echo 'exit 0' | stub git-update
# sqlite3 records its arguments; `.backup '<file>'` creates the file
stub sqlite3 <<'STUB'
printf '%s\n' "$*" >> "$STUB_OUT/sqlite3.calls"
if [[ "${2:-}" == ".backup '"*"'" ]]; then
  dest="${2#.backup \'}"
  echo copied > "${dest%\'}"
fi
exit 0
STUB
# herdr appends each call's arguments, one per line, then an "--end" line
stub herdr <<'STUB'
{ printf '%s\n' "$@"; echo --end; } >> "$STUB_OUT/herdr.calls"
STUB
chmod +x "$stubs"/*

# run_case <name> [claude args...]: a fresh HOME and project (the case's
# files are created by the caller in $home before), output in $out
run_case() {
  out="$root/out-$1"
  shift
  mkdir -p "$out"
  STUB_OUT="$out" \
  PATH="$stubs:$PATH" \
  HOME="$home" \
  XDG_STATE_HOME="$root/state" \
  XDG_RUNTIME_DIR="$root/run" \
  DBUS_SESSION_BUS_ADDRESS=disabled \
  SANDBOX_TEST="${sandbox_test:-1}" \
  STUB_NIX_TRUSTED="${stub_nix_trusted:-0}" \
  CLAUDE_CODE=/nix/store/fake-claude \
  SANDBOX_IMAGE=fake-image \
  NESTED_PODMAN_SETUP=/nix/store/fake-setup \
  NESTED_PODMAN_ENV_BIN=/nix/store/fake-podman/bin \
  DEV_TOOLS_BIN=/nix/store/fake-tools/bin \
  MANAGED_SETTINGS="${managed_settings-/nix/store/fake-managed-settings.json}" \
  ASDF_VM_BIN=/nix/store/fake-asdf/bin \
  CLAUDE_GIT_UPDATE="$stubs/git-update" \
  GIT_SSH_BROKER="${git_ssh_broker:-}" \
  HERDR_ENV="${herdr_env:-}" \
  HERDR_PANE_ID="${herdr_pane:-}" \
  HERDR_BIN="${herdr_bin:-}" \
  GIT_GLOBAL_IGNORE=/nix/store/fake-ignore \
  GIT_GLOBAL_CONFIG=/nix/store/fake-gitconfig \
  CACERT_BUNDLE=/nix/store/fake-ca.crt \
  NIX_DAEMON_SOCKET_DIR="${nix_socket_dir:-$root/no-daemon}" \
  EXTRA_MCP_CONFIG="${extra_mcp:-}" \
  SANDBOX_AGENT="${sandbox_agent:-claude}" \
  SANDBOX_AS="${sandbox_as:-}" \
  KIRO_CLI=/nix/store/fake-kiro \
  XDG_DATA_HOME="$home/.local/share" \
  bash -euo pipefail "$script" "$@" > "$out/stdout" 2> "$out/stderr" \
    || { fail "$out: the launch failed (exit $?)"; cat "$out/stderr" >&2; }
}

# mounts <case>: the -v values of the recorded podman run, one per line
mounts() {
  awk '$0 == "-v" { getline; print }' "$root/out-$1/run.args"
}
has_mount() { mounts "$1" | grep -qxF -- "$2"; }
assert_mount() {  # assert_mount <case> <mount> <what>
  if has_mount "$1" "$2"; then ok "$3"; else fail "$3: no mount '$2' in:"$'\n'"$(mounts "$1")"; fi
}
assert_no_mount() {
  if has_mount "$1" "$2"; then fail "$3: unexpected mount '$2'"; else ok "$3"; fi
}

new_home() {
  home="$root/home-$1"
  proj="$home/proj"
  mkdir -p "$home/.asdf/installs" "$proj" "$root/run"
  cd "$proj"
}

# 1. A read-only path that is a parent of an --add-dir is mounted read-only
# around it; the more specific --add-dir stays read-write (podman stacks by
# depth)
new_home parent
mkdir -p "$home/ws/sub"
SANDBOX_RO_PATHS="$home/ws" run_case parent --add-dir "$home/ws/sub"
assert_mount parent "$home/ws:$home/ws:ro" "RO parent of an --add-dir is read-only"
assert_mount parent "$home/ws/sub:$home/ws/sub:rw" "the --add-dir in it stays read-write"

# 1b. Duplicates: a directory given read-write several ways (--add-dir,
# SANDBOX_ADD_DIRS, settings) is one mount; given read-only as well
# (SANDBOX_RO_PATHS or the configured list, twice) it is one read-only mount
new_home dups
mkdir -p "$home/ws" "$home/cache" "$proj/.claude"
printf '{"permissions":{"additionalDirectories":["%s"]}}\n' "$home/ws" > "$proj/.claude/settings.json"
SANDBOX_ADD_DIRS="$home/ws:$home/ws/:$home/cache" SANDBOX_RO_PATHS="$home/cache:$home/cache/" \
  SANDBOX_CONFIG_RO_PATHS="$home/cache" run_case dups --add-dir "$home/ws" "$home/cache"
if [[ "$(mounts dups | grep -c "^$home/ws:")" == 1 ]] && has_mount dups "$home/ws:$home/ws:rw"; then
  ok "a read-write directory given three ways is one mount"
else
  fail "dups ws: $(mounts dups | grep "$home/ws")"
fi
if [[ "$(mounts dups | grep -c "^$home/cache:")" == 1 ]] && has_mount dups "$home/cache:$home/cache:ro"; then
  ok "a directory given read-write and read-only is one read-only mount"
else
  fail "dups cache: $(mounts dups | grep "$home/cache")"
fi
# 1c. The project itself given read-only is mounted read-only
new_home roproj
SANDBOX_RO_PATHS="$proj" run_case roproj
assert_mount roproj "$proj:$proj:ro" "the project given read-only is read-only"

# 2. A read-only path inside a read-write directory is mounted read-only
new_home inside
mkdir -p "$home/ws/cache"
SANDBOX_RO_PATHS="$home/ws/cache" run_case inside --add-dir "$home/ws"
assert_mount inside "$home/ws:$home/ws:rw" "the --add-dir is read-write"
assert_mount inside "$home/ws/cache:$home/ws/cache:ro" "RO path inside a read-write dir is read-only"

# 3. A main clone's .git given read-write keeps config and hooks read-only
new_home gitdir
mkdir -p "$home/clone/.git"
touch "$home/clone/.git/config"
run_case gitdir --add-dir "$home/clone/.git"
assert_mount gitdir "$home/clone/.git:$home/clone/.git:rw" ".git is read-write"
assert_mount gitdir "$home/clone/.git/config:$home/clone/.git/config:ro" ".git/config is read-only"
assert_mount gitdir "$home/clone/.git/hooks:$home/clone/.git/hooks:ro" ".git/hooks is read-only"

# 3b. A spec/teach-shaped session: a glob deny rule (dir/*/*/*/**) over the
# projects root. The root is read-only (a session can't create files at the
# levels between, or write into a clone made later), each repo already there
# read-only too, a .git given read-write on its own for worktrees with config
# and hooks read-only
new_home projects
mkdir -p "$home/Projects/github/acme/x/.git" "$proj/.claude"
touch "$home/Projects/github/acme/x/.git/config"
printf '{"permissions":{"deny":["Edit(/%s/*/*/*/**)"]}}\n' "$home/Projects" > "$proj/.claude/settings.json"
run_case projects --add-dir "$home/Projects" --add-dir "$home/Projects/github/acme/x/.git"
assert_mount projects "$home/Projects:$home/Projects:ro" "the projects root is read-only"
assert_mount projects "$home/Projects/github/acme/x:$home/Projects/github/acme/x:ro" "a repo in it is read-only"
assert_mount projects "$home/Projects/github/acme/x/.git:$home/Projects/github/acme/x/.git:rw" "its .git is read-write"
assert_mount projects "$home/Projects/github/acme/x/.git/config:$home/Projects/github/acme/x/.git/config:ro" "its .git/config is read-only"
assert_mount projects "$home/Projects/github/acme/x/.git/hooks:$home/Projects/github/acme/x/.git/hooks:ro" "its .git/hooks is read-only"

# 3c. A ticket-shaped session: the repo directory as one writable mount, only
# a cache deny. Clones already in it keep .git/hooks and .git/config
# read-only; a worktree's .git file needs nothing; a symlinked .git is skipped
new_home ticket
mkdir -p "$home/Projects/github/acme/x/.git" "$home/Projects/github/acme/w" "$home/.cache/graph" "$proj/.claude"
touch "$home/Projects/github/acme/x/.git/config"
echo 'gitdir: /elsewhere' > "$home/Projects/github/acme/w/.git"
mkdir -p "$home/Projects/github/acme/x/.git/worktrees/w" "$home/Projects/github/acme/real-git" "$home/Projects/github/acme/under/.git"
touch "$home/Projects/github/acme/x/.git/worktrees/w/commondir" "$home/Projects/github/acme/x/.git/worktrees/w/gitdir"
ln -s "$home/Projects/github/acme/real-git" "$home/Projects/github/acme/sym/.git" 2>/dev/null || { mkdir -p "$home/Projects/github/acme/sym"; ln -s "$home/Projects/github/acme/real-git" "$home/Projects/github/acme/sym/.git"; }
mkdir -p "$home/Projects/github/acme/ro"/{.git,sub}
touch "$home/Projects/github/acme/ro/.git/config"
printf '{"permissions":{"deny":["Edit(/%s/.cache/graph/**)","Edit(/%s/Projects/github/acme/ro/**)"]}}\n' "$home" "$home" > "$proj/.claude/settings.json"
run_case ticket --add-dir "$home/Projects"
assert_mount ticket "$home/Projects:$home/Projects:rw" "the repo directory stays read-write"
assert_mount ticket "$home/Projects/github/acme/x/.git/hooks:$home/Projects/github/acme/x/.git/hooks:ro" "a clone's .git/hooks is read-only"
assert_mount ticket "$home/Projects/github/acme/x/.git/config:$home/Projects/github/acme/x/.git/config:ro" "a clone's .git/config is read-only"
assert_no_mount ticket "$home/Projects/github/acme/w/.git/hooks:$home/Projects/github/acme/w/.git/hooks:ro" "a worktree has no hooks mount"
assert_mount ticket "$home/Projects/github/acme/w/.git:$home/Projects/github/acme/w/.git:ro" "a worktree's .git file is read-only"
assert_mount ticket "$home/Projects/github/acme/x/.git/worktrees/w/commondir:$home/Projects/github/acme/x/.git/worktrees/w/commondir:ro" "a worktree's commondir is read-only"
assert_mount ticket "$home/Projects/github/acme/x/.git/worktrees/w/gitdir:$home/Projects/github/acme/x/.git/worktrees/w/gitdir:ro" "a worktree's gitdir is read-only"
assert_no_mount ticket "$home/Projects/github/acme/x/.git/worktrees:$home/Projects/github/acme/x/.git/worktrees:ro" "worktrees/ itself stays writable"
assert_no_mount ticket "$home/Projects/github/acme/sym/.git/hooks:$home/Projects/github/acme/sym/.git/hooks:ro" "a symlinked .git gets no hooks mount"
assert_no_mount ticket "$home/Projects/github/acme/sym/.git/config:$home/Projects/github/acme/sym/.git/config:ro" "a symlinked .git gets no config mount"
assert_no_mount ticket "$home/Projects/github/acme/ro/.git/hooks:$home/Projects/github/acme/ro/.git/hooks:ro" "a clone under a read-only deny path gets no hooks mount"
assert_no_mount ticket "$home/Projects/github/acme/ro/.git/config:$home/Projects/github/acme/ro/.git/config:ro" "a clone under a read-only deny path gets no config mount"

# 3e. A main clone with a commondir file is already redirected: warned about,
# its whole .git read-only
new_home commondir
mkdir -p "$home/Projects/github/acme/c/.git"
echo /evil > "$home/Projects/github/acme/c/.git/commondir"
run_case commondir --add-dir "$home/Projects"
assert_mount commondir "$home/Projects/github/acme/c/.git:$home/Projects/github/acme/c/.git:ro" "a .git with a commondir is read-only"
if grep -q "c/.git has a commondir" "$root/out-commondir/stderr"; then ok "a commondir warns"; else fail "no commondir warning"; fi

# 3f. A deny glob with a wildcard inside a name does not make the project read-only
new_home dotenv
mkdir -p "$proj/.claude"
printf '{"permissions":{"deny":["Edit(.env*)"]}}\n' > "$proj/.claude/settings.json"
touch "$proj/.env"
run_case dotenv
if grep -q 'mounts: project rw' "$root/out-dotenv/stderr"; then ok "Edit(.env*) leaves the project read-write"; else fail "project not rw: $(grep mounts: "$root/out-dotenv/stderr")"; fi
assert_mount dotenv "$proj/.env:$proj/.env:ro" "the matching file is read-only"

# 3d. Glob expansion keeps a clone path with a space whole and skips a symlink
new_home spaced
mkdir -p "$home/Projects/github/acme/my x/.git" "$home/Projects/github/acme/real" "$proj/.claude"
ln -s "$home/Projects/github/acme/real" "$home/Projects/github/acme/link"
printf '{"permissions":{"deny":["Edit(/%s/*/*/*/**)"]}}\n' "$home/Projects" > "$proj/.claude/settings.json"
run_case spaced --add-dir "$home/Projects"
assert_mount spaced "$home/Projects/github/acme/my x:$home/Projects/github/acme/my x:ro" "a clone path with a space is read-only"
assert_mount spaced "$home/Projects/github/acme/real:$home/Projects/github/acme/real:ro" "a real dir at the matched depth is read-only"
assert_no_mount spaced "$home/Projects/github/acme/link:$home/Projects/github/acme/link:ro" "a symlink at the matched depth is not mounted"

# 4. Without a host ~/.tool-versions, one is generated: the newest version of
# each installed plugin, sorted numerically per dot part, mounted read-only
new_home generated
mkdir -p "$home/.asdf/installs/python/3.9.10" "$home/.asdf/installs/python/3.12.1" \
  "$home/.asdf/installs/python/3.10.0" "$home/.asdf/installs/golang/1.9.7" \
  "$home/.asdf/installs/golang/1.22.3" \
  "$home/.asdf/installs/python/3.14-dev" "$home/.asdf/installs/python/ref-abc" \
  "$home/.asdf/installs/zz"
touch "$home/.asdf/installs/python/x"
run_case generated
if mounts generated | grep -qE ":$home/.tool-versions:ro$"; then
  ok "generated .tool-versions is mounted read-only at ~/.tool-versions"
else
  fail "no ~/.tool-versions mount: $(mounts generated)"
fi
expected=$'golang 1.22.3\npython 3.12.1'  # 3.14-dev, ref-abc, the file x and the empty zz plugin: not picked
if [[ "$(sort "$root/out-generated/tool-versions.copy" 2>/dev/null)" == "$expected" ]]; then
  ok "generated .tool-versions has the newest version of each plugin"
else
  fail "generated .tool-versions: $(cat "$root/out-generated/tool-versions.copy" 2>&1)"
fi

# 5. The host's own ~/.tool-versions keeps its lines; plugins it doesn't name
# get the newest installed version (python is missing from the host file)
new_home hostfile
mkdir -p "$home/.asdf/installs/python/3.12.1" "$home/.asdf/installs/golang/1.22.3" \
  "$home/.asdf/installs/golang/1.9.7"
printf '# mine\ngolang 1.9.7\nnodejs 20.1.0' > "$home/.tool-versions"
run_case hostfile
if mounts hostfile | grep -qE ":$home/.tool-versions:ro\$"; then ok "merged ~/.tool-versions is mounted read-only"; else fail "no ~/.tool-versions mount: $(mounts hostfile)"; fi
expected=$'# mine\ngolang 1.9.7\nnodejs 20.1.0\npython 3.12.1'
if [[ "$(cat "$root/out-hostfile/tool-versions.copy" 2>/dev/null)" == "$expected" ]]; then
  ok "host lines kept as they are, python added, golang not duplicated"
else
  fail "merged .tool-versions: $(cat "$root/out-hostfile/tool-versions.copy" 2>&1)"
fi

# 6. The nix-daemon socket directory is mounted when present, with
# NIX_REMOTE=daemon; absent, nothing is mounted
new_home daemon
mkdir -p "$root/daemon-socket"
nix_socket_dir="$root/daemon-socket" run_case daemon
assert_mount daemon "$root/daemon-socket:$root/daemon-socket" "the nix-daemon socket dir is mounted"
if grep -qxF 'NIX_CONFIG=experimental-features = nix-command flakes' "$root/out-daemon/run.args"; then ok "NIX_CONFIG enables flakes"; else fail "NIX_CONFIG missing"; fi
if grep -qx 'NIX_REMOTE=daemon' "$root/out-daemon/run.args"; then ok "NIX_REMOTE=daemon is set"; else fail "NIX_REMOTE=daemon missing"; fi
new_home nodaemon
run_case nodaemon
assert_no_mount nodaemon "$root/no-daemon:$root/no-daemon" "no nix-daemon mount without the socket dir"
if grep -q NIX_REMOTE "$root/out-nodaemon/run.args"; then fail "NIX_REMOTE set without the daemon"; else ok "no NIX_REMOTE without the daemon"; fi

# 7. A trusted nix user doesn't get the daemon socket (S01); when the daemon
# can't say, it is mounted and logged
new_home trusted
stub_nix_trusted=1 nix_socket_dir="$root/daemon-socket" run_case trusted
assert_no_mount trusted "$root/daemon-socket:$root/daemon-socket" "no nix-daemon mount for a trusted nix user"
if grep -q 'trusted nix user' "$root/out-trusted/stderr"; then ok "trusted nix user: warns"; else fail "no warning for a trusted nix user"; fi
if grep -q NIX_REMOTE "$root/out-trusted/run.args"; then fail "NIX_REMOTE set for a trusted nix user"; else ok "trusted: no NIX_REMOTE"; fi
for answer in none fail; do
  new_home "unknown-$answer"
  SANDBOX_QUIET=1 stub_nix_trusted=$answer nix_socket_dir="$root/daemon-socket" run_case "unknown-$answer"
  assert_no_mount "unknown-$answer" "$root/daemon-socket:$root/daemon-socket" "nix answer '$answer': no daemon mount (fail closed)"
  if grep -q "couldn't tell" "$root/out-unknown-$answer/stderr"; then ok "nix answer '$answer': warned under QUIET"; else fail "nix answer '$answer': no warning"; fi
  if grep -q NIX_REMOTE "$root/out-unknown-$answer/run.args"; then fail "NIX_REMOTE set for unknown trust"; else ok "unknown $answer: no NIX_REMOTE"; fi
done
new_home forced
SANDBOX_NIX_DAEMON=1 stub_nix_trusted=none nix_socket_dir="$root/daemon-socket" run_case forced
assert_mount forced "$root/daemon-socket:$root/daemon-socket" "unknown trust with SANDBOX_NIX_DAEMON=1: mounted"
new_home forcedtrusted
SANDBOX_NIX_DAEMON=1 stub_nix_trusted=1 nix_socket_dir="$root/daemon-socket" run_case forcedtrusted
assert_no_mount forcedtrusted "$root/daemon-socket:$root/daemon-socket" "trusted user with SANDBOX_NIX_DAEMON=1: still not mounted"
new_home falsetrusted
stub_nix_trusted=false nix_socket_dir="$root/daemon-socket" run_case falsetrusted
assert_mount falsetrusted "$root/daemon-socket:$root/daemon-socket" "trusted:false: mounted"
if grep -q "couldn't tell" "$root/out-falsetrusted/stderr"; then fail "trusted:false reported as unknown"; else ok "trusted:false: no 'couldn't tell'"; fi

# 8b. A `..` escape out of /nix/var/nix/ is resolved first and refused (C01)
new_home escape
sandbox_test=0 nix_socket_dir="/nix/var/nix/../../tmp" run_case escape
assert_no_mount escape "/tmp:/tmp" "a .. escape from /nix/var/nix/ is refused"

# 8. NIX_DAEMON_SOCKET_DIR outside /nix/var/nix/ is refused unless the test
# sets SANDBOX_TEST=1 (C04)
new_home outside
sandbox_test=0 nix_socket_dir="$root/daemon-socket" run_case outside
assert_no_mount outside "$root/daemon-socket:$root/daemon-socket" "a NIX_DAEMON_SOCKET_DIR outside /nix/var/nix/ is refused"
if grep -q 'outside /nix/var/nix/' "$root/out-outside/stderr"; then ok "the refusal warns"; else fail "no warning for the refused dir"; fi

# 9. Project = $HOME and no host file: no generated mount, and no mountpoint
# file created on the host (S03)
new_home inhome
cd "$home"
run_case inhome
cd "$proj"
if mounts inhome | grep -q "/.tool-versions"; then fail "tool-versions mounted with \$HOME mounted: $(mounts inhome)"; else ok "no ~/.tool-versions mount when \$HOME is the project"; fi
if [[ -e "$home/.tool-versions" ]]; then fail "a ~/.tool-versions was created on the host"; else ok "nothing created in the host home"; fi

# 10. readOnlyPaths=~/.tool-versions: that one mount only, host file or not (S03)
new_home rofile
echo "python 3.11.0" > "$home/.tool-versions"
SANDBOX_RO_PATHS="$home/.tool-versions" run_case rofile
n=$(mounts rofile | grep -c "/.tool-versions" || true)
if [[ "$n" == 1 ]]; then ok "one ~/.tool-versions mount with readOnlyPaths"; else fail "$n ~/.tool-versions mounts: $(mounts rofile)"; fi

# 11. An empty host ~/.tool-versions counts as absent: one is generated (S03)
new_home emptyfile
mkdir -p "$home/.asdf/installs/python/3.12.1"
: > "$home/.tool-versions"
run_case emptyfile
if [[ "$(cat "$root/out-emptyfile/tool-versions.copy" 2>/dev/null)" == "python 3.12.1" ]]; then ok "empty host file: generated instead"; else fail "empty host file: $(cat "$root/out-emptyfile/tool-versions.copy" 2>&1)"; fi

# 12. An empty plugin dir (after asdf uninstall) and an installs/ with no
# plugins give no mount: the generated file would be empty (C03)
new_home emptyplugin
mkdir -p "$home/.asdf/installs/zz"
run_case emptyplugin
if mounts emptyplugin | grep -q "/.tool-versions"; then fail "mount for an empty plugin dir: $(mounts emptyplugin)"; else ok "no mount with only an empty plugin dir"; fi
new_home noplugins
run_case noplugins
if mounts noplugins | grep -q "/.tool-versions"; then fail "mount with no plugins: $(mounts noplugins)"; else ok "no mount with no plugins"; fi

# 13. Container-only managed settings (kill and delete allow rules) are mounted read-only
new_home managed
run_case managed
assert_mount managed "/nix/store/fake-managed-settings.json:/etc/claude-code/managed-settings.json:ro" "managed settings mounted read-only"
new_home nomanaged
managed_settings="" run_case nomanaged
if mounts nomanaged | grep -q '/etc/claude-code/'; then fail "managed settings mounted without MANAGED_SETTINGS"; else ok "no managed settings mount without MANAGED_SETTINGS"; fi
if grep -q 'MANAGED_SETTINGS is unset' "$root/out-nomanaged/stderr"; then ok "unset MANAGED_SETTINGS warns"; else fail "no warning for unset MANAGED_SETTINGS"; fi

# 13b. The CA bundle is mounted where Dart/pub and Debian tools look for one
assert_mount managed "/nix/store/fake-ca.crt:/etc/pki/tls/certs/ca-bundle.crt:ro" "CA bundle at /etc/pki/tls/certs"
assert_mount managed "/nix/store/fake-ca.crt:/etc/ssl/certs/ca-certificates.crt:ro" "CA bundle at /etc/ssl/certs"

# 14. The user settings reach the container minus the denies the managed
# settings allow (rm -rf); unfiltered without managed settings
new_home filtered
mkdir -p "$home/.claude"
echo '{"permissions":{"deny":["Bash(rm -rf:*)","Bash(git push:*)"],"allow":["Bash(ls:*)"]},"theme":"dark"}' > "$home/.claude/settings.json"
echo '{"permissions":{"allow":["Bash(kill:*)","Bash(rm -rf:*)"]}}' > "$root/managed.json"
managed_settings="$root/managed.json" run_case filtered
if [[ "$(mounts filtered | grep -c ":$home/.claude/settings.json:ro$")" == 1 ]] && ! has_mount filtered "$home/.claude/settings.json:$home/.claude/settings.json:ro"; then
  ok "user settings mounted once, as the filtered copy"
else
  fail "user settings mounts: $(mounts filtered | grep settings.json)"
fi
if jq -e '.permissions.deny == ["Bash(git push:*)"] and .permissions.allow == ["Bash(ls:*)"] and .theme == "dark"' "$root/out-filtered/settings.copy" > /dev/null; then
  ok "the managed allow lifts the matching deny, the rest is kept"
else
  fail "filtered settings: $(cat "$root/out-filtered/settings.copy" 2>/dev/null)"
fi
new_home unfiltered
mkdir -p "$home/.claude"
echo '{"permissions":{"deny":["Bash(rm -rf:*)"]}}' > "$home/.claude/settings.json"
run_case unfiltered
assert_mount unfiltered "$home/.claude/settings.json:$home/.claude/settings.json:ro" "no readable managed settings: the user settings as they are"

# 15. git-ssh-broker (GIT_SSH_BROKER, a real broker when the test is given
# one): its git socket is mounted with GIT_SSH_COMMAND; with a signing key
# and a host agent, the agent socket too, the key read-only, and signing
# stays on. Without the broker, signing is off.
gitenv() { grep -E '^(GIT_|SSH_AUTH_SOCK=)' "$root/out-$1/run.args" || true; }
new_home nobroker
run_case nobroker
if gitenv nobroker | grep -qx 'GIT_CONFIG_KEY_2=commit.gpgSign' && gitenv nobroker | grep -qx 'GIT_CONFIG_VALUE_2=false'; then
  ok "no broker: commit signing is off"
else
  fail "no broker: signing not turned off: $(gitenv nobroker)"
fi
if gitenv nobroker | grep -q '^GIT_SSH_COMMAND='; then fail "no broker: GIT_SSH_COMMAND set"; else ok "no broker: no GIT_SSH_COMMAND"; fi
if [[ -n "${GIT_SSH_BROKER:-}" ]] && command -v ssh-agent >/dev/null && command -v ssh-keygen >/dev/null; then
  new_home broker
  mkdir -p "$home/.ssh"
  ssh-keygen -q -t ed25519 -N '' -f "$home/.ssh/work" >/dev/null
  touch "$home/.ssh/allowed_signers"
  ssh-agent -D -a "$root/agent.sock" >/dev/null 2>&1 &
  agent_pid=$!
  for _ in $(seq 1 50); do [[ -S "$root/agent.sock" ]] && break; sleep 0.1; done
  git_ssh_broker="$GIT_SSH_BROKER" SSH_AUTH_SOCK="$root/agent.sock" SANDBOX_SIGNING_KEYS="$home/.ssh/work.pub:$home/.ssh/missing.pub" \
    run_case broker
  kill "$agent_pid" 2>/dev/null || true
  if mounts broker | grep -qE '/git\.sock:.*/git\.sock$'; then ok "broker: git socket mounted"; else fail "broker: no git socket mount: $(mounts broker)"; fi
  if mounts broker | grep -qE '/agent\.sock:.*/agent\.sock$'; then ok "broker: agent socket mounted"; else fail "broker: no agent socket mount: $(mounts broker)"; fi
  assert_mount broker "$home/.ssh/work.pub:$home/.ssh/work.pub:ro" "broker: signing key mounted read-only"
  assert_mount broker "$home/.ssh/allowed_signers:$home/.ssh/allowed_signers:ro" "broker: allowed signers mounted read-only"
  assert_no_mount broker "$home/.ssh/missing.pub:$home/.ssh/missing.pub:ro" "broker: a missing key is skipped"
  if gitenv broker | grep -qx "GIT_SSH_COMMAND=$GIT_SSH_BROKER client" && gitenv broker | grep -qx 'GIT_SSH_VARIANT=ssh' \
    && gitenv broker | grep -qE '^SSH_AUTH_SOCK=.*/agent\.sock$'; then
    ok "broker: GIT_SSH_COMMAND and SSH_AUTH_SOCK point at the broker"
  else
    fail "broker: env: $(gitenv broker)"
  fi
  if gitenv broker | grep -q 'gpgSign'; then fail "broker: signing turned off: $(gitenv broker)"; else ok "broker: signing stays on"; fi
  if mounts broker | grep -q '\.1password\|/run/user'; then fail "broker: a host agent is mounted: $(mounts broker)"; else ok "broker: no host agent mounted"; fi
else
  echo "skip: broker cases (set GIT_SSH_BROKER to a git-ssh-broker binary; needs ssh-agent, ssh-keygen)"
fi

# herdr: in a herdr pane, a directory for the status line's usage file is
# mounted and named in SANDBOX_HERDR_DIR, and the launcher clears the
# pane's usage rows on exit; outside one, neither
home="$root/home-herdr"
mkdir -p "$home/proj"
cd "$home/proj"
STUB_USAGE='ctx 12k\n\n\n5h ▰▱▱▱▱ 20%\e[31m\n' \
  herdr_env=1 herdr_pane=w1:p1 herdr_bin="$stubs/herdr" run_case herdr
herdr_dir="$(awk '$0 == "-e" { getline; if (sub(/^SANDBOX_HERDR_DIR=/, "")) print }' "$root/out-herdr/run.args")"
if [[ -n "$herdr_dir" ]] && has_mount herdr "$herdr_dir:$herdr_dir"; then
  ok "herdr: the usage directory is mounted and named"
else
  fail "herdr: dir '$herdr_dir', mounts: $(mounts herdr)"
fi
if grep -qx 'ctx_ok=ctx 12k' "$root/out-herdr/herdr.calls" 2>/dev/null \
  && grep -qx 'five_hour=5h ▰▱▱▱▱ 20%\[31m' "$root/out-herdr/herdr.calls" \
  && grep -qx 'reset=' "$root/out-herdr/herdr.calls"; then
  ok "herdr: the container's usage file is reported, control characters removed"
else
  fail "herdr: calls: $(cat "$root/out-herdr/herdr.calls" 2>/dev/null)"
fi
if [[ "$(sed -n '/^--token$/{n;p}' "$root/out-herdr/herdr.calls" 2>/dev/null | tail -10 | grep -c '=$')" == 10 ]] \
  && grep -qx 'w1:p1' "$root/out-herdr/herdr.calls"; then
  ok "herdr: the pane's usage rows are cleared on exit"
else
  fail "herdr: calls: $(cat "$root/out-herdr/herdr.calls" 2>/dev/null)"
fi
if [[ -n "$herdr_dir" && ! -e "$herdr_dir" ]]; then
  ok "herdr: the usage directory is removed"
else
  fail "herdr: $herdr_dir is left behind"
fi
herdr_bin="$stubs/herdr" run_case noherdr
if grep -q SANDBOX_HERDR_DIR "$root/out-noherdr/run.args" || [[ -e "$root/out-noherdr/herdr.calls" ]]; then
  fail "noherdr: relay set up outside herdr"
else
  ok "noherdr: no relay outside herdr"
fi

# kiro (SANDBOX_AGENT=kiro, modules/apps/kiro/kiro-sandbox.nix)
# K1. The host's ~/.kiro is never mounted writable: the sandbox's own state
# dirs are, with the host's agents/skills/steering read-only on top and a
# throwaway settings copy whose mcp.json merges the host's servers with the
# extra ones. Nothing of Claude's is mounted; kiro-cli gets the arguments
# untouched (no --mcp-config, no --plugin-dir)
new_home kiro
mkdir -p "$home/.kiro/agents" "$home/.kiro/skills" "$home/.kiro/settings" "$home/.kiro/workspace-roots/x"
echo '{"chat.agentEngine":"v3"}' > "$home/.kiro/settings/cli.json"
echo '{"mcpServers":{"host":{"command":"h"},"dup":{"command":"old"}}}' > "$home/.kiro/settings/mcp.json"
echo '{"mcpServers":{"extra":{"command":"/nix/store/x"},"dup":{"command":"new"}}}' > "$root/kiro-extra-mcp.json"
mkdir -p "$home/.local/share/kiro-cli"
echo host-db > "$home/.local/share/kiro-cli/data.sqlite3"
sandbox_agent=kiro extra_mcp="$root/kiro-extra-mcp.json" run_case kiro chat --add-dir /nope
state="$home/.local/share/kiro-sandbox"
assert_mount kiro "$state/kiro:$home/.kiro:rw" "kiro: ~/.kiro is the sandbox's own"
assert_mount kiro "$state/data:$home/.local/share/kiro-cli:rw" "kiro: the kiro-cli data dir is the sandbox's own"
assert_mount kiro "$home/.kiro/agents:$home/.kiro/agents:ro" "kiro: host agents read-only"
assert_mount kiro "$home/.kiro/skills:$home/.kiro/skills:ro" "kiro: host skills read-only"
assert_no_mount kiro "$home/.kiro/steering:$home/.kiro/steering:ro" "kiro: a missing host dir isn't mounted"
if mounts kiro | grep -qE "^$home/\.kiro(/[^:]*)?:[^:]*:rw\$"; then fail "kiro: a host ~/.kiro path is writable: $(mounts kiro)"; else ok "kiro: no host ~/.kiro path is writable"; fi
if mounts kiro | grep -qE '/\.claude|claude-code'; then fail "kiro: Claude mounts: $(mounts kiro)"; else ok "kiro: nothing of Claude's is mounted"; fi
if mounts kiro | grep -qE ":$home/\.kiro/settings:rw\$" && [[ -f "$root/out-kiro/kiro-settings.copy/cli.json" ]]; then
  ok "kiro: a copy of the host settings is mounted"
else
  fail "kiro: no settings copy: $(mounts kiro)"
fi
if jq -e '.mcpServers == {host: {command: "h"}, dup: {command: "new"}, extra: {command: "/nix/store/x"}}' "$root/out-kiro/kiro-settings.copy/mcp.json" > /dev/null 2>&1; then
  ok "kiro: mcp.json merges the host's servers with the extra ones (extra wins)"
else
  fail "kiro: mcp.json: $(cat "$root/out-kiro/kiro-settings.copy/mcp.json" 2>&1)"
fi
if tail -n 5 "$root/out-kiro/run.args" | tr '\n' ' ' | grep -qF "/nix/store/fake-kiro/bin/kiro-cli chat --trust-all-tools --add-dir /nope "; then
  ok "kiro: kiro-cli runs with the arguments, trusting all tools"
else
  fail "kiro: command: $(tail -n 5 "$root/out-kiro/run.args")"
fi
if jq -e '."chat.agentEngine" == "v3" and ."chat.disableTrustAllConfirmation" == true' "$root/out-kiro/kiro-settings.copy/cli.json" > /dev/null 2>&1 \
  && ! grep -q disableTrustAllConfirmation "$home/.kiro/settings/cli.json"; then
  ok "kiro: the settings copy (not the host's) skips the trust-all confirmation"
else
  fail "kiro: cli.json copy: $(cat "$root/out-kiro/kiro-settings.copy/cli.json" 2>&1)"
fi
if grep -qx -- '--name' "$root/out-kiro/run.args" && grep -qE '^kiro-sandbox-.*-kiro$' "$root/out-kiro/run.args"; then
  ok "kiro: the container is <pod>-kiro in a kiro-sandbox pod"
else
  fail "kiro: container name: $(grep -A1 -x -- --name "$root/out-kiro/run.args")"
fi
if mounts kiro | grep -q '/etc/claude-code/' || grep -q 'MANAGED_SETTINGS' "$root/out-kiro/stderr"; then fail "kiro: managed settings involved"; else ok "kiro: no managed settings"; fi
# K2. The host login is never copied or read: a chat in a terminal logs in
# first when the sandbox isn't (kiro-cli whoami || kiro-cli login, then the
# chat); other subcommands and headless runs start kiro-cli directly
if [[ -e "$state/data/data.sqlite3" || -e "$root/out-kiro/sqlite3.calls" ]]; then
  fail "kiro: the host login is copied: $(cat "$root/out-kiro/sqlite3.calls" 2>&1)"
else
  ok "kiro: the host login isn't copied into the sandbox"
fi
login_first() {  # login_first <case>: the run is wrapped in the login check
  grep -qxF -- kiro-login "$root/out-$1/run.args" && grep -qF 'login --use-device-flow' "$root/out-$1/run.args"
}
if login_first kiro; then fail "kiro: a headless chat is wrapped in the login check"; else ok "kiro: a headless chat doesn't log in by itself"; fi
SANDBOX_TEST_TTY=1 sandbox_agent=kiro run_case kirologin chat --resume
if login_first kirologin \
  && awk 'f { printf "%s ", $0 } $0 == "kiro-login" { f = 1 }' "$root/out-kirologin/run.args" \
    | grep -qxF "/nix/store/fake-kiro/bin/kiro-cli chat --trust-all-tools --resume "; then
  ok "kiro: a chat in a terminal logs in first, then runs the chat"
else
  fail "kiro: login first: $(tail -n 12 "$root/out-kirologin/run.args")"
fi
SANDBOX_TEST_TTY=1 sandbox_agent=kiro run_case kirologin-none
if login_first kirologin-none; then ok "kiro: no arguments (a chat) logs in first too"; else fail "kiro: no login check without arguments"; fi
SANDBOX_TEST_TTY=1 sandbox_agent=kiro run_case kirologin-sub whoami
if login_first kirologin-sub; then fail "kiro: a subcommand is wrapped in the login check"; else ok "kiro: other subcommands don't log in by themselves"; fi
SANDBOX_TEST_TTY=1 run_case kirologin-claude
if grep -qxF -- kiro-login "$root/out-kirologin-claude/run.args"; then fail "claude: wrapped in kiro's login check"; else ok "claude: no kiro login check"; fi
# the check itself, run with a fake kiro-cli: logged out it logs in, then
# execs the chat; logged in it goes straight to the chat; a failed login
# stops there
fake_kiro="$root/fake-kiro-cli"
cat > "$fake_kiro" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_KIRO_CALLS"
case "$1" in
  whoami) [[ -e "$FAKE_KIRO_LOGGED_IN" ]] ;;
  login) [[ "${FAKE_KIRO_LOGIN_FAILS:-0}" == 1 ]] && exit 3; touch "$FAKE_KIRO_LOGGED_IN" ;;
esac
FAKE
chmod +x "$fake_kiro"
login_script="$(awk 'p == 2 && $0 == "kiro-login" { exit } p == 2 { print } p == 1 && $0 == "-c" { p = 2 } $0 == "/nix/store/fake-setup" { p = 1 }' "$root/out-kirologin/run.args")"
login_check() {  # login_check <calls file>: run the check around a chat
  FAKE_KIRO_CALLS="$1" bash -c "$login_script" kiro-login "$fake_kiro" chat --x
}
export FAKE_KIRO_LOGGED_IN="$root/fake-kiro-logged-in"
rm -f "$FAKE_KIRO_LOGGED_IN"
login_check "$root/kiro-calls-out" 2>/dev/null
if [[ "$(tr '\n' '|' < "$root/kiro-calls-out")" == "whoami|login --use-device-flow|chat --x|" ]]; then
  ok "kiro login check: logged out, it logs in and then starts the chat"
else
  fail "kiro login check (logged out): $(cat "$root/kiro-calls-out" 2>&1)"
fi
login_check "$root/kiro-calls-in" 2>/dev/null
if [[ "$(tr '\n' '|' < "$root/kiro-calls-in")" == "whoami|chat --x|" ]]; then
  ok "kiro login check: logged in, the chat starts directly"
else
  fail "kiro login check (logged in): $(cat "$root/kiro-calls-in" 2>&1)"
fi
rm -f "$FAKE_KIRO_LOGGED_IN"
if FAKE_KIRO_LOGIN_FAILS=1 login_check "$root/kiro-calls-fail" 2>/dev/null; then
  fail "kiro login check: a failed login still exits 0"
elif [[ "$(tr '\n' '|' < "$root/kiro-calls-fail")" == "whoami|login --use-device-flow|" ]]; then
  ok "kiro login check: a failed login doesn't start the chat"
else
  fail "kiro login check (login fails): $(cat "$root/kiro-calls-fail" 2>&1)"
fi
unset FAKE_KIRO_LOGGED_IN
# K3. SANDBOX_ADD_DIRS mounts read-write (with the clones' git
# protection) and SANDBOX_RO_PATHS read-only, added to the configured
# paths; an old agent-named setting gets a warning
new_home kirodirs
mkdir -p "$home/ws/repo/.git" "$home/cache" "$home/configured"
touch "$home/ws/repo/.git/config"
# shellcheck disable=SC2088 # a literal ~, expanded by the launcher
SANDBOX_CONFIG_RO_PATHS="$home/configured" SANDBOX_ADD_DIRS="~/ws" SANDBOX_RO_PATHS="$home/cache" \
  KIRO_SANDBOX_ADD_DIRS="$home/old" sandbox_agent=kiro run_case kirodirs
assert_mount kirodirs "$home/ws:$home/ws:rw" "kiro: SANDBOX_ADD_DIRS is read-write"
assert_mount kirodirs "$home/ws/repo/.git/config:$home/ws/repo/.git/config:ro" "kiro: a clone's .git/config in it is read-only"
assert_mount kirodirs "$home/cache:$home/cache:ro" "kiro: SANDBOX_RO_PATHS is read-only"
assert_mount kirodirs "$home/configured:$home/configured:ro" "kiro: SANDBOX_RO_PATHS adds to the configured read-only paths"
if grep -q 'KIRO_SANDBOX_ADD_DIRS is no longer read; use SANDBOX_ADD_DIRS' "$root/out-kirodirs/stderr"; then
  ok "kiro: an old agent-named setting gets a warning"
else
  fail "kiro: no warning for KIRO_SANDBOX_ADD_DIRS: $(cat "$root/out-kirodirs/stderr")"
fi
# K3b. SANDBOX_ADD_DIRS mounts for claude too, without becoming an
# --add-dir of claude's (mounts only)
new_home claudedirs
mkdir -p "$home/ws"
SANDBOX_ADD_DIRS="$home/ws" run_case claudedirs
assert_mount claudedirs "$home/ws:$home/ws:rw" "claude: SANDBOX_ADD_DIRS is read-write"
if grep -qx -- "--add-dir=$home/ws" "$root/out-claudedirs/run.args" || grep -qx -- "--add-dir" "$root/out-claudedirs/run.args"; then
  fail "claude: SANDBOX_ADD_DIRS became an --add-dir"
else
  ok "claude: SANDBOX_ADD_DIRS isn't passed to claude"
fi
# K4. kiro-sandbox --help describes the kiro sandbox
sandbox_agent=kiro sandbox_as=kiro-sandbox run_case kirohelp --help
if grep -q 'SANDBOX_ADD_DIRS' "$root/out-kirohelp/stdout" && [[ ! -e "$root/out-kirohelp/run.args" ]]; then
  ok "kiro-sandbox --help prints the kiro help"
else
  fail "kiro-sandbox --help: $(head -3 "$root/out-kirohelp/stdout")"
fi
# K5. Trust all tools: only chats (no arguments starts one) get the flag; a
# trust flag given wins; SANDBOX_TRUST_ALL=0 passes the arguments as
# they are
kiro_cmd() {  # kiro_cmd <case>: what runs in the container after the setup
  awk -v s=/nix/store/fake-setup 'f { printf "%s ", $0 } $0 == s { f = 1 }' "$root/out-$1/run.args"
}
assert_kiro_cmd() {  # assert_kiro_cmd <case> <expected command> <what>
  if [[ "$(kiro_cmd "$1")" == "$2 " ]]; then ok "$3"; else fail "$3: ran '$(kiro_cmd "$1")'"; fi
}
k=/nix/store/fake-kiro/bin/kiro-cli
new_home kirotrust
sandbox_agent=kiro run_case kirotrust-none
assert_kiro_cmd kirotrust-none "$k chat --trust-all-tools" "kiro: no arguments starts a chat trusting all tools"
sandbox_agent=kiro run_case kirotrust-login login --use-device-flow
assert_kiro_cmd kirotrust-login "$k login --use-device-flow" "kiro: other subcommands are left alone"
sandbox_agent=kiro run_case kirotrust-given chat --trust-tools=fs_read --resume
assert_kiro_cmd kirotrust-given "$k chat --trust-tools=fs_read --resume" "kiro: a trust flag given wins"
sandbox_agent=kiro run_case kirotrust-a chat -a
assert_kiro_cmd kirotrust-a "$k chat -a" "kiro: -a isn't doubled"
sandbox_agent=kiro run_case kirotrust-sep chat -- -a
assert_kiro_cmd kirotrust-sep "$k chat --trust-all-tools -- -a" "kiro: a -a after -- is the prompt, not a flag"
SANDBOX_TRUST_ALL=0 sandbox_agent=kiro run_case kirotrust-off chat
assert_kiro_cmd kirotrust-off "$k chat" "kiro: SANDBOX_TRUST_ALL=0 keeps kiro's prompts"
if [[ -e "$root/out-kirotrust-off/kiro-settings.copy/cli.json" ]] \
  && grep -q disableTrustAllConfirmation "$root/out-kirotrust-off/kiro-settings.copy/cli.json"; then
  fail "kiro: the trust-all confirmation is skipped with SANDBOX_TRUST_ALL=0"
else
  ok "kiro: SANDBOX_TRUST_ALL=0 leaves the settings copy alone"
fi
run_case kirotrust-claude
if kiro_cmd kirotrust-claude | grep -q -- --trust-all-tools; then fail "claude: given --trust-all-tools"; else ok "claude: no kiro trust flag"; fi
# K6. herdr usage rows for kiro: read from the session file kiro-cli writes
# in the sandbox's ~/.kiro (nothing mounted for it); "usage ERROR" when its
# records don't read as expected; cleared on exit
kiro_herdr_case() {  # kiro_herdr_case <case> <session lines>
  new_home "$1"
  local h
  h="$(printf '%s' "$proj" | sha256sum | cut -c1-16)"
  STUB_KIRO_FILE="$home/.local/share/kiro-sandbox/kiro/sessions/$h/sess_t/messages.jsonl" STUB_KIRO_SESSION="$2" \
    sandbox_agent=kiro herdr_env=1 herdr_pane=w1:p2 herdr_bin="$stubs/herdr" run_case "$1" chat
}
reported() {  # reported <case> <token=value>: some report-metadata call had it
  grep -qxF -- "$2" "$root/out-$1/herdr.calls" 2>/dev/null
}
meta='{"id":"1","payload":{"type":"session_metadata","key":"contextUsage","value":{"usagePercentage":%s}}}\n'
turn='{"id":"2","payload":{"type":"usage_summary","promptTurnSummaries":[{"unit":"credit","unitPlural":"credits","usage":%s}]}}\n'
# shellcheck disable=SC2059 # the formats are the records above
kiro_herdr_case kiroherdr "{\"id\":\"0\",\"payload\":{\"type\":\"other\"}}\n$(printf "$meta" 12)\n$(printf "$turn" 1.5)\n$(printf "$meta" 65.4)\n$(printf "$turn" 2.25)\n"
if reported kiroherdr 'ctx_warn=ctx 65%' && reported kiroherdr 'credits=3.75 credits' && reported kiroherdr 'kiro-usage' \
  && reported kiroherdr 'w1:p2'; then
  ok "kiro herdr: the context used and the session's credits are reported"
else
  fail "kiro herdr: calls: $(cat "$root/out-kiroherdr/herdr.calls" 2>/dev/null)"
fi
if grep -q SANDBOX_HERDR_DIR "$root/out-kiroherdr/run.args"; then fail "kiro herdr: a usage dir is mounted"; else ok "kiro herdr: nothing is mounted for it"; fi
if [[ "$(sed -n '/^--token$/{n;p}' "$root/out-kiroherdr/herdr.calls" 2>/dev/null | tail -5 | grep -c '=$')" == 5 ]]; then
  ok "kiro herdr: the pane's usage rows are cleared on exit"
else
  fail "kiro herdr: calls: $(cat "$root/out-kiroherdr/herdr.calls" 2>/dev/null)"
fi
# shellcheck disable=SC2059
kiro_herdr_case kiroherdrhot "$(printf "$meta" 85)\n"
if reported kiroherdrhot 'ctx_hot=ctx 85%' && reported kiroherdrhot 'credits=' && reported kiroherdrhot 'usage_error='; then
  ok "kiro herdr: from 80% the context is hot; no credits before a turn ends"
else
  fail "kiro herdr hot: calls: $(cat "$root/out-kiroherdrhot/herdr.calls" 2>/dev/null)"
fi
# shellcheck disable=SC2059
kiro_herdr_case kiroherdrbad "$(printf "$meta" '"x"')\n"
if reported kiroherdrbad 'usage_error=usage ERROR' && ! reported kiroherdrbad 'ctx_ok=ctx' \
  && grep -q 'warning: kiro usage: .*contextUsage has no numeric usagePercentage' "$root/state/kiro-sandbox.log"; then
  ok "kiro herdr: a changed record shows usage ERROR, the reason in the launch log"
else
  fail "kiro herdr bad: calls: $(cat "$root/out-kiroherdrbad/herdr.calls" 2>/dev/null)"
fi
kiro_herdr_case kiroherdrjson '{"payload":{"type":"usage_summary", not json\n'
if reported kiroherdrjson 'usage_error=usage ERROR'; then
  ok "kiro herdr: records that aren't JSON show usage ERROR"
else
  fail "kiro herdr json: calls: $(cat "$root/out-kiroherdrjson/herdr.calls" 2>/dev/null)"
fi
# shellcheck disable=SC2059
kiro_herdr_case kiroherdrunit "$(printf "$meta" 10)\n{\"payload\":{\"type\":\"usage_summary\",\"promptTurnSummaries\":[{\"unit\":\"token\",\"usage\":5}]}}\n"
if reported kiroherdrunit 'usage_error=usage ERROR'; then
  ok "kiro herdr: turn summaries without credits show usage ERROR"
else
  fail "kiro herdr unit: calls: $(cat "$root/out-kiroherdrunit/herdr.calls" 2>/dev/null)"
fi
new_home kironoherdr
sandbox_agent=kiro herdr_bin="$stubs/herdr" run_case kironoherdr chat
if [[ -e "$root/out-kironoherdr/herdr.calls" ]]; then fail "kiro: relay outside herdr"; else ok "kiro: no relay outside herdr"; fi

# P1. An agent profile (AGENT_HOME, set by the wrapper from AGENT): claude's
# config dir is the profile home, mounted read-write with CLAUDE_CONFIG_DIR;
# ~/.claude isn't mounted
new_home profclaude
ph="$home/.config/agents/homes/work-claude"
mkdir -p "$ph/skills" "$home/.claude"
echo '{"permissions":{"deny":["Bash(rm -rf:*)"]}}' > "$ph/settings.json"
AGENT_HOME="$ph" AGENT_PROFILE=work-claude run_case profclaude
assert_mount profclaude "$ph:$ph:rw" "profile: claude's home is the profile's"
assert_mount profclaude "$ph/.claude.json:$ph/.claude.json:rw" "profile: .claude.json is in the profile home"
assert_mount profclaude "$ph/skills:$ph/skills:ro" "profile: its skills are read-only"
if mounts profclaude | grep -q ":$ph/settings.json:ro\$"; then ok "profile: its settings are read-only"; else fail "profile settings: $(mounts profclaude)"; fi
assert_no_mount profclaude "$home/.claude:$home/.claude:rw" "profile: ~/.claude isn't mounted"
if grep -qx "CLAUDE_CONFIG_DIR=$ph" "$root/out-profclaude/run.args" && grep -qx "claude-sandbox.profile=work-claude" "$root/out-profclaude/run.args"; then
  ok "profile: CLAUDE_CONFIG_DIR and the pod's profile label are set"
else
  fail "profile env: $(grep -E 'CLAUDE_CONFIG_DIR|profile' "$root/out-profclaude/run.args")"
fi
# P2. kiro: the profile home's config (read-only) and login, its sandbox
# state in <home>/.sandbox
new_home profkiro
ph="$home/.config/agents/homes/work-kiro"
mkdir -p "$ph/agents" "$ph/settings" "$ph/.data/kiro-cli" "$home/.kiro/skills"
echo '{"mcpServers":{"mine":{"command":"m"}}}' > "$ph/settings/mcp.json"
echo db > "$ph/.data/kiro-cli/data.sqlite3"
AGENT_HOME="$ph" AGENT_PROFILE=work-kiro sandbox_agent=kiro run_case profkiro chat
assert_mount profkiro "$ph/.sandbox/kiro:$home/.kiro:rw" "profile kiro: its sandbox ~/.kiro is in the profile home"
assert_mount profkiro "$ph/.sandbox/data:$home/.local/share/kiro-cli:rw" "profile kiro: its sandbox data dir too"
assert_mount profkiro "$ph/agents:$home/.kiro/agents:ro" "profile kiro: the profile's agents, read-only"
assert_no_mount profkiro "$home/.kiro/skills:$home/.kiro/skills:ro" "profile kiro: ~/.kiro isn't used"
if jq -e '.mcpServers.mine' "$root/out-profkiro/kiro-settings.copy/mcp.json" >/dev/null 2>&1 \
  && [[ ! -e "$ph/.sandbox/data/data.sqlite3" ]]; then
  ok "profile kiro: the profile's MCP servers are used, its open login isn't copied"
else
  fail "profile kiro: $(ls "$ph/.sandbox/data" 2>&1)"
fi

if (( failures > 0 )); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all claude-sandbox checks passed"
