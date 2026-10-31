# Components updated outside `nix flake update`

`nix flake update` only moves what's in `flake.lock`. Everything below is
pinned or fetched separately and has to be checked and bumped by hand.
Keep this list current whenever you add a pin, override, image or download.

## Pinned in Nix (bump version + hash together)

| Component | Pinned | Where | How to update |
|---|---|---|---|
| claude-code | nixpkgs' version at `flake.lock` | `programs.claudeSandbox.package` (default `pkgs.claude-code`, `modules/apps/claude/claude-sandbox.nix`), used by `claude` (sandboxed), `claude-sandbox` and `claude-open` | Moves with `nix flake update nixpkgs` plus a switch; check it with `nix eval --raw nixpkgs#claude-code.version`. Launches no longer evaluate or download anything. To run ahead of nixpkgs, set the option to an overridden package. |
| kiro-cli | nixpkgs' version at `flake.lock` | `programs.kiroSandbox.package` (default `pkgs.kiro-cli-unwrapped`, in the container) and `programs.kiroSandbox.openPackage` (default `pkgs.kiro-cli`, for `kiro-open`), `modules/apps/kiro/kiro-sandbox.nix` | Moves with `nix flake update nixpkgs` plus a switch; check it with `nix eval --raw nixpkgs#kiro-cli-unwrapped.version`. nixpkgs trails upstream (the installer's self-updating `~/.local/bin/kiro-cli` is separate and untouched). To run ahead, override the package's `version` and `src` hash. After a bump, check a sandboxed kiro chat in herdr still shows its `ctx`/credits rows: they read kiro's undocumented session records (`kiro_usage` in `claude-sandbox.sh`) and turn into a red `usage ERROR` when those change. |
| proton-drive-cli | 0.8.0 | `pkgs/proton-drive-cli/default.nix` (`version`, sha512 `hash`) | Set the new version, put a dummy hash, build, copy the hash from the error. |
| asdf-vm override | 0.20.2 | `hosts/common.nix` overlay | Workaround: nixpkgs' 0.20.1 tag was deleted upstream. **Remove the override** once nixpkgs ships asdf-vm ≥ 0.20.2. |
| xwayland-satellite override | 0.8.1 | `hosts/common.nix` overlay | Workaround: 0.8.2 broke Steam popups under niri (Supreeeme/xwayland-satellite#468, #503). **Remove the override** once nixpkgs has a release with the fix. |
| teamviewer patchelf override | patchelf 0.15.2 (teamviewer itself still follows nixpkgs) | `modules/corp/teamviewer.nix` (`patchelf_0_15`) | Workaround: patchelf ≥ 0.18 writes a teamviewerd whose RW LOAD segment overlaps the code segment, so it segfaults in ld.so. To check whether you can **remove the override**: drop it, build `.#nixosConfigurations.framework-work.config.services.teamviewer.package`, and run `<out>/share/teamviewer/tv_bin/.teamviewerd-wrapped -h`. Exit 1 means it works; exit 139 (segfault) means the bug is still there. |
| Claude skills from git | none yet | `modules/apps/claude/claude-code.nix` (`skillSources`) | Each entry is pinned by `rev`: `git ls-remote <url> <ref>`, then update `rev`. |

## Container images pinned by digest

Each reference is `<image>:<exact tag>@sha256:<digest>`, where the digest is
the multi-arch index's. Podman pulls exactly that, and a bump pulls the new
one on next use (no manual `podman pull`). To bump, pick the new tag
(`crane ls <image> | sort -V | tail`), get its index digest
(`crane digest <image>:<tag>`; `nix shell nixpkgs#crane` provides crane),
and replace both the tag and the digest.

| Image | Pinned | Where | Notes |
|---|---|---|---|
| `docker.io/library/caddy` | 2.11.6 | `modules/apps/sandbox-proxy/sandbox-proxy.sh` (`CADDY_IMAGE`) | registry-proxy and mcp-proxy. Images are part of sandbox-proxy's container fingerprint (the script is hashed), so the next `sandbox-proxy start` (any claude-sandbox launch) recreates them. |
| `docker.io/library/registry` | 2.8.3 | same file (`REGISTRY_IMAGE`) | The pull-through image cache. `registry:3` exists; a major bump needs a config check. |
| `docker.io/verdaccio/verdaccio` | 5.33.0 | same file (`VERDACCIO_IMAGE`) | The npm cache. 6.x exists (6.5.2); a major bump needs its config checked. |
| `docker.io/library/debian` | trixie-20260918-slim (Debian 13.7) | `programs.claudeSandbox.image` (`modules/apps/claude/claude-sandbox.nix`); `DEBIAN_IMAGE` in `sandbox-proxy.sh` (`prune`) | The container Claude and kiro run in (kiro-sandbox uses the same option); it brings nothing but a base system, since tools come from `/nix/store`. Keep both copies on the same digest so only one is stored. |

## Floating: updated outside Nix entirely

| Component | Tracks | Where | How to update |
|---|---|---|---|
| Container image | `node:<version>` | `modules/apps/npm-sandbox/npm-sandbox.sh` | Version comes from each project's asdf `nodejs`; follows `.tool-versions`. |
| Flatpaks | Flathub | `profiles/*.nix`, `modules/apps/*` (`services.flatpak.packages`) | nix-flatpak installs them but doesn't update them (no `update.onActivation`). Run `flatpak update`. |
| asdf plugins and tools | per project | `programs.asdf.plugins` in profiles, `.tool-versions` in projects | `asdf plugin update --all`; tool versions are per project. Pythons are built from source against nix store paths: `modules/apps/asdf/` roots them (`asdf-gcroots`, run before every `nix.gc`; only on hosts with `programs.asdf.plugins`); after a GC-damaged install it re-fetches them, and `asdf-gcroots --list` shows what an install needs. The unit has no `wantedBy`: nix-gc requires and runs it first, so the first manual `sudo systemctl start asdf-gcroots` after a switch is optional (it only roots paths before the first GC). Check: `systemctl status asdf-gcroots nix-gc`, `journalctl -u asdf-gcroots`. Unrealisable paths only warn (exit 0; reinstall the tool to fix); an install that can't be read (read errors) only warns and keeps its roots, but when every install fails that way the script exits 1 (see `journalctl -u asdf-gcroots`: "first read error in ..."); a hard failure (that, nix-store missing, mkdir error, timeout) fails the unit and so holds nix-gc back. |
| asdf `flutter` | 3.10.4 (pre-installed) | `programs.asdf.versions` in `profiles/desktop.nix` | Pre-installed by the `asdf-install` user service (`modules/apps/zsh/zsh.nix`) on switch; projects pick a version in `.tool-versions`. Add or change the version there; old installs stay until `asdf uninstall flutter <version>`. |

## Not independent (listed so they aren't mistaken for pins)

- `tix` (ticket workflow, Obsidian vault setup) is a flake input, locked in `flake.lock` like the others: `nix flake update tix`. Bump it after pushing there. Its own pins (Obsidian plugins) are in its `UPDATES.md`.
- `mouse-debounce` is source in this repo (`modules/hardware/mouse-debounce/src`), with no upstream.

## Removed

| Component | Removed | Why |
|---|---|---|
| graphify (sandbox sidecar, its pinned pip lock and Python image, the `graphify` Claude skill, the SessionStart hook pointing Claude at it) | 2026-10-30 | An A/B run over 10 codebase questions (one run per arm, with and without the graph) showed no accuracy gain, about 6% higher cost and about a minute of extra startup per session. Agents used it at most once per question before falling back to search. |
| fff (the `fff` flake input and its MCP server in every sandboxed session) | 2026-10-30 | In the same kind of A/B run agents never called it: they searched with the built-in Grep and Glob, at no worse accuracy. Claude's LSP tool (`programs.claudeSandbox.lspServers`, servers from nixpkgs) replaces it for references and callers. |

## Quick check

```sh
# latest upstream releases for the pinned items
nix eval --raw nixpkgs#asdf-vm.version; echo                       # drop override when >= 0.20.2
nix eval --raw nixpkgs#xwayland-satellite.version; echo            # drop override when fixed
nix eval --raw nixpkgs#claude-code.version; echo                   # claude-code you get after a flake update
nix eval --raw nixpkgs#kiro-cli-unwrapped.version; echo            # kiro-cli you get after a flake update
# newest tags of the pinned images (then crane digest <image>:<tag>)
for i in library/caddy library/registry verdaccio/verdaccio library/debian; do
  echo "$i: $(nix shell nixpkgs#crane -c crane ls docker.io/$i | grep -E '^[0-9]+(\.[0-9]+)+(-slim(-trixie)?)?$|^trixie-[0-9]+-slim$' | sort -V | tail -n 2 | tr '\n' ' ')"
done
```
