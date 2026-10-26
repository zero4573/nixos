# claude-sandbox

`claude` (and its alias `claude-sandbox`) runs Claude Code inside a privileged,
rootless podman container scoped to the current directory. `claude-open` runs the
same pinned claude-code unsandboxed. All three first fast-forward a git checkout
in the current directory to its upstream (`claude-git-update.sh`); diverged
branches or local changes are reported and left alone.

The module is `modules/apps/claude/claude-sandbox.nix` (a home-manager module,
`programs.claudeSandbox.*`); the launcher is `claude-sandbox.sh`. `claude-sandbox
--help` documents every setting.

## Launch

```mermaid
sequenceDiagram
    participant U as user
    participant L as claude-sandbox.sh
    participant P as sandbox-proxy
    participant D as host nix-daemon
    participant C as container: claude
    U->>L: claude [args]
    L->>L: parse --add-dir, --settings, --mcp-config, path flags
    L->>L: git fetch and fast-forward the checkout
    L->>P: sandbox-proxy start (reuses running containers)
    L->>L: create pod in aisandbox.slice, start graphify sidecar
    L->>L: compute mounts from Claude settings
    L->>L: generate ~/.tool-versions
    L->>D: nix store info --json: is the user trusted?
    D-->>L: trusted yes, no or unknown
    L->>C: podman run with mounts, env and PATH
    C-->>U: claude session
    U->>L: exit
    L->>L: remove pod and temp files
```

Each step is timestamped on stderr and appended to
`~/.local/state/claude-sandbox.log`, so a stuck launch shows where it is.

## Mounts

What the session can touch follows Claude's own settings, not sandbox flags:

- read-write: the working directory and every `--add-dir` directory (also
  `permissions.additionalDirectories` from user, project and `--settings`);
- read-only: paths of `Edit(...)` / `Write(...)` deny rules that lie inside a
  read-write directory (the most specific path wins), files named by
  `--settings`, `--mcp-config`, `--plugin-dir` and `--*system-prompt-file`, and
  `programs.claudeSandbox.readOnlyPaths`;
- `/nix/store` read-only, `~/.claude` read-write (its settings, skills and
  agents read-only), the asdf data dir read-only, any vault's `.obsidian/`
  read-only.

## nix-daemon socket and trust

`/nix/var/nix/daemon-socket` is mounted with `NIX_REMOTE=daemon`, so `nix eval`
and `nix flake check --no-build` work inside the sandbox. The trade-off: anything
in the sandbox can talk to the daemon as the invoking user and ask the host to
evaluate, fetch and build. `/nix/store` itself stays read-only.

That is only acceptable for an untrusted nix user. The launcher asks the daemon
(`nix store info --json`, field `trusted`) and decides:

```mermaid
flowchart TD
    q["nix store info --json"] --> t{"trusted?"}
    t -->|"no"| mount["mount the socket"]
    t -->|"yes (root-equivalent)"| skip["skip, warn"]
    t -->|"unknown"| env{"CLAUDE_SANDBOX_NIX_DAEMON=1?"}
    env -->|"yes"| mount
    env -->|"no (fails closed)"| skip
```

A user in `nix.settings.trusted-users` never gets the socket.

## `.tool-versions` fallback

asdf shims read `$HOME/.tool-versions` when no nearer file sets a tool, so
`python3`, `go` and `gofmt` would fail in a directory without one. The launcher
mounts a generated `~/.tool-versions` read-only: the host's own lines unchanged,
plus the newest installed version of every asdf plugin the host file does not
name (numeric `sort -V`; names like `3.14-dev` only count when no numeric one
exists). A `.tool-versions` nearer the working directory wins. If `$HOME` itself
is mounted, no file is generated.

## Dev tools and PATH

Inside the container `PATH` is, in order: asdf shims, asdf-vm, the nested podman
toolchain, the dev-tools environment, claude-code, then the image's `/usr/bin`.
The dev tools (`devToolsEnv` in the module) are built from the host's nixpkgs and
reached through the read-only store mount: git, coreutils and friends, ripgrep,
fd, jq, yq, archive tools, process and network tools, make, shellcheck,
Jujutsu (`jj`, for tidying unpushed history in a scratch clone), the `nix` client
and `programs.claudeSandbox.extraPackages`. The nested podman toolchain lets the
session run containers of its own. `openssh` is there for `ssh-keygen` only (no
sshd, no ssh config).

## Kill commands

Claude Code's permission layer (not the OS) stops `kill`, `pkill` and `killall`
by default. The launcher mounts a Nix-generated managed-settings file read-only
at `/etc/claude-code/managed-settings.json` that allows `Bash(kill:*)`,
`Bash(pkill:*)` and `Bash(killall:*)` in the container only; the host's
settings are unchanged.

## Other pieces

- **graphify sidecar** (`claude-sandbox-graphify-sidecar.sh`): builds a code
  knowledge graph of the project and every `--add-dir` codebase and serves it as
  the `graphify` MCP server on the pod's localhost. Skip it with
  `CLAUDE_SANDBOX_NO_GRAPHIFY=1`.
- **extra MCP servers**: `programs.claudeSandbox.extraMcpServers` (by default
  `fff`) are merged with the proxy's and graphify's.
- **resource limits**: pod and containers run under `aisandbox.slice`.
- **pins**: the images (by digest), claude-code (flake nixpkgs) and graphify (hashed
  pip lock) are pinned; see [`UPDATES.md`](../UPDATES.md).
