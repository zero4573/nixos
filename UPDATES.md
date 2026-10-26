# Components updated outside `nix flake update`

`nix flake update` only moves what's in `flake.lock`. Everything below is
pinned or fetched separately and has to be checked and bumped by hand.
Keep this list current whenever you add a pin, override, image or download.

## Pinned in Nix (bump version + hash together)

| Component | Pinned | Where | How to update |
|---|---|---|---|
| graphify (sandbox sidecar) | graphifyy 0.9.73 with its extras and all 67 dependencies, in a hashed pip lock for Python 3.12 / x86_64 Linux | `modules/apps/claude/claude-sandbox-graphify-requirements.txt` (the lock), `programs.claudeSandbox.graphifyVersion` / `graphifyExtras` (defaults in `modules/apps/claude/claude-sandbox.nix`) | 1. **Lock first:** `claude-sandbox-graphify-lock <new version> [<extras,comma,separated>] > modules/apps/claude/claude-sandbox-graphify-requirements.txt`. The installed helper takes the new version as an argument, so you don't need a rebuild for this step; its defaults are the current options. 2. Set `graphifyVersion` (and `graphifyExtras`) to match. The build fails while the lock's `# spec:` line doesn't match the options. Review the extras against the release's `provides_extra`, since new language extras appear over time. 3. The sidecar installs the new lock with `pip --require-hashes` into a new venv on its next start. 4. Check that `graphify serve` still hot-reloads on mtime. Also refresh `graphify_code_re` in `modules/apps/claude/claude-sandbox.sh` (the preflight's copy of `graphify.detect.CODE_EXTENSIONS`). Re-running step 1 with the **same** version picks up dependency fixes. Keep it close to the auto-updated skill (below), and to claude-tickets' own lock (its `UPDATES.md`). |
| claude-code | nixpkgs' version at `flake.lock` | `programs.claudeSandbox.package` (default `pkgs.claude-code`, `modules/apps/claude/claude-sandbox.nix`), used by `claude` (sandboxed), `claude-sandbox` and `claude-open` | Moves with `nix flake update nixpkgs` plus a switch; check it with `nix eval --raw nixpkgs#claude-code.version`. Launches no longer evaluate or download anything. To run ahead of nixpkgs, set the option to an overridden package. |
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
| `docker.io/library/debian` | trixie-20260918-slim (Debian 13.7) | `programs.claudeSandbox.image` (`modules/apps/claude/claude-sandbox.nix`); `DEBIAN_IMAGE` in `sandbox-proxy.sh` (`prune`) | The container Claude runs in; it brings nothing but a base system, since tools come from `/nix/store`. Keep both copies on the same digest so only one is stored. |
| `docker.io/library/python` | 3.12.15-slim-trixie | `programs.claudeSandbox.graphifyImage` (same file): the graphify sidecar | **The Python minor version must match the graphify lock's** (`graphifyPython` in `claude-sandbox.nix`; the build checks it). Patch bumps are free. For a minor bump, change `graphifyPython`, then regenerate the lock. |

## Floating: updated outside Nix entirely

| Component | Tracks | Where | How to update |
|---|---|---|---|
| Container image | `node:<version>` | `modules/apps/npm-sandbox/npm-sandbox.sh` | Version comes from each project's asdf `nodejs`; follows `.tool-versions`. |
| Flatpaks | Flathub | `profiles/*.nix`, `modules/apps/*` (`services.flatpak.packages`) | nix-flatpak installs them but doesn't update them (no `update.onActivation`). Run `flatpak update`. |
| asdf plugins and tools | per project | `programs.asdf.plugins` in profiles, `.tool-versions` in projects | `asdf plugin update --all`; tool versions are per project. Pythons are built from source against nix store paths: `modules/apps/asdf/` roots them (`asdf-gcroots`, run before every `nix.gc`; only on hosts with `programs.asdf.plugins`); after a GC-damaged install it re-fetches them, and `asdf-gcroots --list` shows what an install needs. The unit has no `wantedBy`: nix-gc requires and runs it first, so the first manual `sudo systemctl start asdf-gcroots` after a switch is optional (it only roots paths before the first GC). Check: `systemctl status asdf-gcroots nix-gc`, `journalctl -u asdf-gcroots`. Unrealisable paths only warn (exit 0; reinstall the tool to fix); an install that can't be read (read errors) only warns and keeps its roots, but when every install fails that way the script exits 1 (see `journalctl -u asdf-gcroots`: "first read error in ..."); a hard failure (that, nix-store missing, mkdir error, timeout) fails the unit and so holds nix-gc back. |
| graphify Claude skill | latest GitHub release | `modules/apps/claude/claude-code.nix` (`claudeCodeGraphifySkill`) | Automatic on every switch, nothing to do. It can run ahead of the pinned sidecar version above. |

## Not independent (listed so they aren't mistaken for pins)

- `claude-tickets` (ticket workflow, Obsidian vault setup) is a flake input, locked in `flake.lock` like the others: `nix flake update claude-tickets`. Bump it after pushing there. Its own pins (Obsidian plugins, graphify image) are in its `UPDATES.md`.
- `mouse-debounce` is source in this repo (`modules/hardware/mouse-debounce/src`), with no upstream.

## Quick check

```sh
# latest upstream releases for the pinned items
curl -s https://pypi.org/pypi/graphifyy/json | jq -r '"graphifyy " + .info.version'
nix eval --raw nixpkgs#asdf-vm.version; echo                       # drop override when >= 0.20.2
nix eval --raw nixpkgs#xwayland-satellite.version; echo            # drop override when fixed
nix eval --raw nixpkgs#claude-code.version; echo                   # claude-code you get after a flake update
# newest tags of the pinned images (then crane digest <image>:<tag>)
for i in library/caddy library/registry verdaccio/verdaccio library/debian library/python; do
  echo "$i: $(nix shell nixpkgs#crane -c crane ls docker.io/$i | grep -E '^[0-9]+(\.[0-9]+)+(-slim(-trixie)?)?$|^trixie-[0-9]+-slim$' | sort -V | tail -n 2 | tr '\n' ' ')"
done
```
