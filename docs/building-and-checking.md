# Building and checking

```sh
nix flake check --no-build              # evaluate every module, host and check
nix build .#nixosConfigurations.<host>.config.system.build.toplevel --dry-run
./nixos-rebuild.sh <host>                # nixos-rebuild switch --sudo --flake .#<host>
```

`<host>` is `framework-work`, `framework-personal` or `vm`. Only `vm` is meant to
be rebuilt from a dev machine: the framework hosts need real hardware, and disko
partitions real disks, so do not switch them without confirming the target device.

## Script checks

The sandbox, agents and asdf-gcroots scripts each have a flake check (shellcheck
plus a test script) and can be run directly. The `claude-sandbox` check runs
`claude-sandbox-test.sh` (stub podman and systemd-run) and
`claude-sandbox-self-check-test.sh` with the real git-ssh-broker and
review-broker, because their socket cases need them. The `agents` check runs
`agents-test.sh` against stub wrappers.

```sh
bash modules/apps/claude/claude-sandbox-test.sh   # launcher with a stubbed podman: asserts the mount list
bash modules/apps/asdf/asdf-gcroots-test.sh       # GC roots, run with a minimal PATH
shellcheck -s bash modules/apps/claude/*.sh modules/apps/asdf/*.sh
nix build .#checks.x86_64-linux.claude-sandbox .#checks.x86_64-linux.asdf-gcroots
```

```mermaid
flowchart LR
    eval["nix flake check --no-build"] --> cfgs["host configurations evaluate"]
    build["nix build .#checks.x86_64-linux.NAME"] --> sc["shellcheck"]
    build --> tst["test script with stubs"]
    tst --> mounts["claude-sandbox: mount list, trust decision, .tool-versions"]
    tst --> roots["asdf-gcroots: roots, pruning, failure modes"]
```

`nix flake check --no-build` only evaluates, so the script checks need an explicit
build (or the direct `bash` run) to execute. Pinned values that `flake.lock` does
not cover are listed in [`UPDATES.md`](../UPDATES.md) with how to bump them.

## Go packages

Building a Go package runs its tests: `nix build .#git-ssh-broker` (real git push
and ssh-agent), `.#review-broker` (stub kiro launcher), `.#mcp-guard`. Each can
also run with `go test ./...` in its source directory.
