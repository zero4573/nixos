# AGENTS.md

Instructions for AI coding agents working in this repository.

## What this is

A NixOS flake managing three hosts via flake-parts + `import-tree`, following the
**dendritic pattern**: every `.nix` file under a directory that's fed to `import-tree`
is itself a flake-parts module (signature `{ self, inputs, ... }: { ... }`), not a
plain NixOS module. Fine-grained modules expose `flake.nixosModules.<name>`; coarse
"profiles" import several of them; hosts compose profiles. There is no single
top-down `configuration.nix` — everything is assembled from `self.nixosModules.*`.

For the in-progress multi-host buildout plan and decisions log, see `plan.md`.

## Directory layout

```
flake.nix                       inputs, nixConfig, perSystem pkgs (allowUnfree), imports
options.nix                     flake.nixosModules.hostOptions — the hostConfig.* namespace
hosts/common.nix                commonConfigs — reads hostConfig.* (stateVersion, timezone, git, ...)
hosts/<host>/{default,settings,disko}.nix   per-host nixosConfigurations + hostConfig values
profiles/{desktop,work,personal,vm-guest}.nix   composition layer over modules/
modules/desktop/{audio,fonts,portals,networking}.nix
modules/apps/{browsers,terminals,dev,containers,screenshot,onepassword,work-autostart}.nix
modules/corp/{tailscale,globalprotect,teamviewer,zscaler,beyondtrust,work-flatpaks}.nix
modules/flatpak/flatpak.nix
modules/hardware/framework.nix
modules/home/{home-manager,desktop-home,users}.nix
modules/niri/niri.nix           niri wrapper package + keybinds (host-agnostic)
modules/noctalia/, modules/thunar/
```

Hosts:
- **framework-work** — primary daily desktop; `workProfile` (desktop + corp tools + work autostart); disko btrfs+LUKS.
- **framework-personal** — secondary desktop, separate disk; `personalProfile` (desktop + Steam flatpak); disko btrfs+LUKS.
- **vm** — throwaway test VM; imports `workProfile` too, so it mirrors framework-work's *software* set on VM hardware (ext4/grub, no disko).

## Conventions

- **Every new file under `modules/`, `profiles/`, or `hosts/` must be a flake-parts
  module**: `{ self, inputs, ... }: { flake.nixosModules.<name> = { ... }: { ... }; }`.
  Use `_:` for the outer function head if `self`/`inputs` are unused.
- Reference other modules via `self.nixosModules.<name>` / `self.homeModules.<name>`,
  never by filesystem path — the flake namespace is the contract, not the directory.
- Per-host values (user, timezone, git identity, profile) go through `hostConfig.*`
  (defined in `options.nix`), set in each host's `settings.nix`. Don't hardcode
  usernames or emails in shared modules.
- `specialArgs = { inherit self inputs; }` is set per-host in `default.nix` so profile
  modules can reach `inputs`/`self` at NixOS-eval time.
- New nixpkgs-backed inputs go in `flake.nix`; new module trees are picked up
  automatically since `modules/`, `profiles/`, `hosts/` are already `import-tree`'d —
  no need to edit the `imports` list in `flake.nix` for a new file, only for a new
  top-level directory.
- Corp tools not packaged in nixpkgs (zscaler, beyondtrust) are intentionally
  no-op placeholder modules with a TODO comment explaining the packaging approach
  (autoPatchelfHook / buildFHSEnv) — keep them evaluable, don't delete them.
- niri stays **host-agnostic** (`modules/niri/niri.nix`): keybinds/spawn-at-startup
  live there for all hosts. Profile-specific autostart (1Password, Teams PWA) goes
  in a profile module as gated systemd user services, not into niri directly.

## Building / checking

```sh
nix flake check --no-build              # fast: evaluate all modules/configs
nix build .#nixosConfigurations.<host>.config.system.build.toplevel --dry-run
./nixos-config.sh <host>                 # sudo nixos-rebuild switch --flake .#<host>
```

`<host>` is one of `framework-work`, `framework-personal`, `vm`. Only `vm` can
actually be rebuilt/tested from a dev machine; the framework hosts need real
hardware (disko will partition real disks — do not build/switch those without
explicit confirmation of the target device).

## Gotchas

- `inputs.vicinae` must **not** get `inputs.nixpkgs.follows` — it has its own cachix
  binary cache; following breaks it and forces a from-source rebuild (including Qt).
- podman: `dockerCompat` gives a `docker` alias — never add `pkgs.docker` alongside it.
- disko owns root/boot filesystems on the framework hosts — hardware modules for
  those hosts must not also declare `fileSystems."/"` etc.
- `config.nix` (repo root) is gitignored (machine-local override) but does not
  currently exist in this checkout — don't assume it's present.
