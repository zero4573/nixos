# Components updated outside `nix flake update`

`nix flake update` only moves what's in `flake.lock`. Everything below is
pinned or fetched separately and has to be checked and bumped by hand.
Keep this list current whenever you add a pin, override, image or download.

## Pinned in Nix (bump version + hash together)

| Component | Pinned | Where | How to update |
|---|---|---|---|
| Obsidian Tasks plugin | 8.4.0 | `modules/apps/obsidian/obsidian.nix` (`tasksVersion`, 3× sha256) | `nix-prefetch-url https://github.com/obsidian-tasks-group/obsidian-tasks/releases/download/<v>/{main.js,manifest.json,styles.css}`. **Seeded only into vaults that don't have it yet**, so a bump only reaches new vaults; existing vaults update through Obsidian's in-app updater. |
| Obsidian Minimal theme | 9.0.2 | same file (`minimalVersion`, 2× sha256) | `nix-prefetch-url https://github.com/kepano/obsidian-minimal/releases/download/<v>/{theme.css,manifest.json}`. **Held back:** 9.1.x needs Obsidian ≥ 1.14 and Flathub ships 1.13.7. Check the release's `manifest.json` `minAppVersion` against `flatpak info md.obsidian.Obsidian`. Same seed-once caveat as Tasks. |
| graphify (sandbox sidecar) | graphifyy 0.9.73 | `modules/apps/claude/claude-sandbox.nix` (`graphifyVersion`) | Set to the latest PyPI `graphifyy` release; the sidecar reinstalls into the `claude-sandbox-graphify` volume on the next start. Only graphify itself is pinned; pip resolves its dependencies. Keep it close to the auto-updated skill (below). Also refresh `graphify_code_re` in `modules/apps/claude/claude-sandbox.sh` (the preflight's copy of `graphify.detect.CODE_EXTENSIONS`). |
| proton-drive-cli | 0.8.0 | `pkgs/proton-drive-cli/default.nix` (`version`, sha512 `hash`) | Set the new version, put a dummy hash, build, copy the hash from the error. |
| asdf-vm override | 0.20.2 | `hosts/common.nix` overlay | Workaround: nixpkgs' 0.20.1 tag was deleted upstream. **Remove the override** once nixpkgs ships asdf-vm ≥ 0.20.2. |
| xwayland-satellite override | 0.8.1 | `hosts/common.nix` overlay | Workaround: 0.8.2 broke Steam popups under niri (Supreeeme/xwayland-satellite#468, #503). **Remove the override** once nixpkgs has a release with the fix. |
| Claude skills from git | none yet | `modules/apps/claude/claude-code.nix` (`skillSources`) | Each entry is pinned by `rev`: `git ls-remote <url> <ref>`, then update `rev`. |

## Floating: updated outside Nix entirely

| Component | Tracks | Where | How to update |
|---|---|---|---|
| Container images | `caddy:latest`, `registry:2`, `verdaccio/verdaccio:5` | `modules/apps/sandbox-proxy/sandbox-proxy.sh` | Pulled once and **never refreshed** (podman's default pull policy is "missing"). Run `podman pull docker.io/library/caddy:latest docker.io/library/registry:2 docker.io/verdaccio/verdaccio:5`, then `sandbox-proxy start`. Also consider major bumps (`registry:3`, `verdaccio:6`). |
| Container images | `debian:stable-slim`, `python:3.12-slim` | `modules/apps/claude/claude-sandbox.sh` | `--pull=missing`, so same as above: `podman pull docker.io/library/debian:stable-slim docker.io/library/python:3.12-slim`. Python's minor version is pinned in the tag; bump it deliberately. |
| Container image | `node:<version>` | `modules/apps/npm-sandbox/npm-sandbox.sh` | Version comes from each project's asdf `nodejs`; follows `.tool-versions`. |
| Flatpaks | Flathub | `profiles/*.nix`, `modules/apps/*` (`services.flatpak.packages`) | nix-flatpak installs them but doesn't update them (no `update.onActivation`). Run `flatpak update`. |
| asdf plugins and tools | per project | `programs.asdf.plugins` in profiles, `.tool-versions` in projects | `asdf plugin update --all`; tool versions are per project. |
| graphify Claude skill | latest GitHub release | `modules/apps/claude/claude-code.nix` (`claudeCodeGraphifySkill`) | Automatic on every switch, nothing to do. It can run ahead of the pinned sidecar version above. |

## Not independent (listed so they aren't mistaken for pins)

- `claude-code` in claude-sandbox (`nix build --impure nixpkgs#claude-code`) and the host `claude` wrapper (`nix-shell -p claude-code`) resolve `nixpkgs` via the flake registry and `NIX_PATH`. NixOS points both at the system's locked nixpkgs, so they move with `flake.lock` after a switch.
- `mouse-debounce` is source in this repo (`modules/hardware/mouse-debounce/src`), with no upstream.

## Quick check

```sh
# latest upstream releases for the pinned items
for r in obsidian-tasks-group/obsidian-tasks kepano/obsidian-minimal; do
  curl -sL -o /dev/null -w "$r %{url_effective}\n" "https://github.com/$r/releases/latest"
done
curl -s https://pypi.org/pypi/graphifyy/json | jq -r '"graphifyy " + .info.version'
flatpak remote-info flathub md.obsidian.Obsidian | grep Version   # gate for Minimal 9.1+
nix eval --raw nixpkgs#asdf-vm.version; echo                       # drop override when >= 0.20.2
nix eval --raw nixpkgs#xwayland-satellite.version; echo            # drop override when fixed
```
