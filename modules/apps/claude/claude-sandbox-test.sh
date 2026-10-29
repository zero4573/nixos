#!/usr/bin/env bash
# Test of claude-sandbox.sh: runs it with stubs for everything it launches
# (podman, systemd-run, ...) first on PATH, in a throwaway HOME and project,
# and asserts the -v mount list handed to `podman run`. Needs bash, jq, git
# and coreutils. Usage: claude-sandbox-test.sh [path to claude-sandbox.sh]
# (default: the sibling script). Also a flake check, claude-sandbox-check.nix.
set -euo pipefail

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
  prev=
  for a in "$@"; do
    if [[ "$prev" == -v && "$a" == *:*/.tool-versions:ro ]]; then
      cp "${a%%:*}" "$STUB_OUT/tool-versions.copy"
    fi
    if [[ "$prev" == -v && "$a" == *:*/.claude/settings.json:ro ]]; then
      cp "${a%%:*}" "$STUB_OUT/settings.copy"
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
  CLAUDE_SANDBOX_NO_GRAPHIFY=1 \
  CLAUDE_SANDBOX_TEST="${sandbox_test:-1}" \
  STUB_NIX_TRUSTED="${stub_nix_trusted:-0}" \
  CLAUDE_CODE=/nix/store/fake-claude \
  CLAUDE_SANDBOX_IMAGE=fake-image \
  NESTED_PODMAN_SETUP=/nix/store/fake-setup \
  NESTED_PODMAN_ENV_BIN=/nix/store/fake-podman/bin \
  DEV_TOOLS_BIN=/nix/store/fake-tools/bin \
  MANAGED_SETTINGS="${managed_settings-/nix/store/fake-managed-settings.json}" \
  ASDF_VM_BIN=/nix/store/fake-asdf/bin \
  CLAUDE_GIT_UPDATE="$stubs/git-update" \
  GIT_SSH_BROKER="${git_ssh_broker:-}" \
  GIT_GLOBAL_IGNORE=/nix/store/fake-ignore \
  GIT_GLOBAL_CONFIG=/nix/store/fake-gitconfig \
  CACERT_BUNDLE=/nix/store/fake-ca.crt \
  NIX_DAEMON_SOCKET_DIR="${nix_socket_dir:-$root/no-daemon}" \
  GRAPHIFY_SIDECAR="" GRAPHIFY_IMAGE="" GRAPHIFY_LOCK="" GRAPHIFY_INSTALL="" EXTRA_MCP_CONFIG="" \
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

# 1. A read-only path that is a parent of an --add-dir is skipped, with a
# warning, and not mounted read-only over it
new_home parent
mkdir -p "$home/ws/sub"
CLAUDE_SANDBOX_RO_PATHS="$home/ws" run_case parent --add-dir "$home/ws/sub"
assert_no_mount parent "$home/ws:$home/ws:ro" "RO parent of an --add-dir is not mounted"
assert_mount parent "$home/ws/sub:$home/ws/sub:rw" "the --add-dir stays read-write"
if grep -q "contains the read-write directory $home/ws/sub" "$root/out-parent/stderr"; then
  ok "RO parent of an --add-dir warns"
else
  fail "no warning for the RO parent; stderr: $(cat "$root/out-parent/stderr")"
fi

# 2. A read-only path inside a read-write directory is mounted read-only
new_home inside
mkdir -p "$home/ws/cache"
CLAUDE_SANDBOX_RO_PATHS="$home/ws/cache" run_case inside --add-dir "$home/ws"
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

# 3b. A kb/teach-shaped session: a glob deny rule (dir/*/*/*/**) over the
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
  CLAUDE_SANDBOX_QUIET=1 stub_nix_trusted=$answer nix_socket_dir="$root/daemon-socket" run_case "unknown-$answer"
  assert_no_mount "unknown-$answer" "$root/daemon-socket:$root/daemon-socket" "nix answer '$answer': no daemon mount (fail closed)"
  if grep -q "couldn't tell" "$root/out-unknown-$answer/stderr"; then ok "nix answer '$answer': warned under QUIET"; else fail "nix answer '$answer': no warning"; fi
  if grep -q NIX_REMOTE "$root/out-unknown-$answer/run.args"; then fail "NIX_REMOTE set for unknown trust"; else ok "unknown $answer: no NIX_REMOTE"; fi
done
new_home forced
CLAUDE_SANDBOX_NIX_DAEMON=1 stub_nix_trusted=none nix_socket_dir="$root/daemon-socket" run_case forced
assert_mount forced "$root/daemon-socket:$root/daemon-socket" "unknown trust with CLAUDE_SANDBOX_NIX_DAEMON=1: mounted"
new_home forcedtrusted
CLAUDE_SANDBOX_NIX_DAEMON=1 stub_nix_trusted=1 nix_socket_dir="$root/daemon-socket" run_case forcedtrusted
assert_no_mount forcedtrusted "$root/daemon-socket:$root/daemon-socket" "trusted user with CLAUDE_SANDBOX_NIX_DAEMON=1: still not mounted"
new_home falsetrusted
stub_nix_trusted=false nix_socket_dir="$root/daemon-socket" run_case falsetrusted
assert_mount falsetrusted "$root/daemon-socket:$root/daemon-socket" "trusted:false: mounted"
if grep -q "couldn't tell" "$root/out-falsetrusted/stderr"; then fail "trusted:false reported as unknown"; else ok "trusted:false: no 'couldn't tell'"; fi

# 8b. A `..` escape out of /nix/var/nix/ is resolved first and refused (C01)
new_home escape
sandbox_test=0 nix_socket_dir="/nix/var/nix/../../tmp" run_case escape
assert_no_mount escape "/tmp:/tmp" "a .. escape from /nix/var/nix/ is refused"

# 8. NIX_DAEMON_SOCKET_DIR outside /nix/var/nix/ is refused unless the test
# sets CLAUDE_SANDBOX_TEST=1 (C04)
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
CLAUDE_SANDBOX_RO_PATHS="$home/.tool-versions" run_case rofile
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
  git_ssh_broker="$GIT_SSH_BROKER" SSH_AUTH_SOCK="$root/agent.sock" CLAUDE_SANDBOX_SIGNING_KEYS="$home/.ssh/work.pub:$home/.ssh/missing.pub" \
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

if (( failures > 0 )); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all claude-sandbox checks passed"
