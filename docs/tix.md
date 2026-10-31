# tix wiring

`modules/apps/tix.nix` provides `flake.homeModules.tixSetup`,
which connects the tix flake input (the ticket workflow and Obsidian
vaults, its own repository) to this machine.

```mermaid
flowchart LR
    input["flake input: tix"] --> setup["tixSetup home module"]
    setup -->|"container podman, aisandbox.slice"| sandbox["claude-sandbox"]
    setup -->|"TIX_* passEnv, models cache read-only"| sandbox
    setup -->|"sessionSettings"| rules["ticket and spec session rules"]
    setup -->|"tixd function"| zsh["zsh"]
    sandbox --> proxy["sandbox-proxy MCP"]
```

## What it sets

- The sandbox runs in podman under `aisandbox.slice`; `TIX_*`
  variables are passed into it and the model cache under
  `$XDG_CACHE_HOME/tix/models` is mounted read-only.
- Ticket and spec sessions commit on their branches, signed through
  git-ssh-broker's agent, and push through the broker, which refuses force pushes
  and branch or tag deletes.
- `sessionSettings.permissions.deny` adds the rules those sessions never get
  (`git reset --hard`, `git branch -D`, ...), on top of tix's own
  (the graph cache read-only; spec sessions also stay out of the repos). The
  workspace settings file is read-only in the sandbox, so a session can't relax
  them.
- Exception to that deny list: the lead adds and removes git worktrees, one per
  task under the ticket workspace's `tasks/`, and removes each once its branch
  is merged, deleting the branch ref with `git update-ref -d` after checking
  it is merged (`git branch -d` would write the main clone's read-only config;
  `-D` stays denied).
- `sessionSettings.autoCompactWindow = 260000`: ticket sessions compact just
  past tix's last context warning (250k tokens). The PO checkpoints its board and
  relay at the warnings, and tix's SessionStart hook resumes it afterwards.
- Rovo tools that consume paid credits are denied.
- `SANDBOX_*` set in the shell that runs `tix` reach that one session (claude's
  or kiro's sandbox), because the session runs in the foreground of that shell
  and inherits its environment: `SANDBOX_PORTS=3000 tix start PROJ-12`. tix adds
  the directories a session needs to `SANDBOX_ADD_DIRS` and the model cache to
  `SANDBOX_RO_PATHS` itself.
- Vaults whose `.workflow.json` says `"agent": "kiro"` (or `TIX_AGENT=kiro`,
  `--agent kiro`) run their sessions in the kiro sandboxes: `programs.tix.kiro =
  "kiro"`. `AGENT=<profile>` picks the claude or kiro account for either
  ([agents](./agents.md)); tix doesn't need to know.
- `tixd work|tickets|repos` is a zsh function: it runs `tix dir <arg>` and `cd`s
  to the printed directory (a command can't change the shell's directory).

## Flow: opening a directory

```mermaid
sequenceDiagram
    participant U as user
    participant Z as zsh tixd
    participant T as tix dir
    U->>Z: tixd tickets
    Z->>T: tix dir tickets
    T-->>Z: path of the current vault's directory
    Z->>Z: cd to the path, only when tix succeeded
```
