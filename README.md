# nixos-config

A multi-host NixOS flake (flake-parts + `import-tree`, dendritic pattern) covering:

- **framework-work** — primary daily desktop; standard desktop + corporate tooling (VPN,
  Teams, 1Password, Intune, etc.). btrfs + LUKS via disko.
- **framework-personal** — secondary desktop on separate physical storage; standard desktop
  + Steam. btrfs + LUKS via disko.
- **vm** — throwaway test VM that mirrors framework-work's *software* profile on VM hardware.
  Also btrfs + LUKS via disko, on the VM's virtio disk. Used to test changes before they
  touch real hardware.

See [`AGENTS.md`](./AGENTS.md) for the directory layout and module conventions

## Installing (framework-work / framework-personal / vm)

All three hosts install the same way: boot the **official NixOS installer ISO** (minimal or
graphical), use disko to declaratively partition + LUKS-encrypt + format the disk, then
`nixos-install`. `vm` additionally needs the VM itself created first (see below) before you
boot the ISO inside it.

> The official ISO doesn't enable flakes by default — every `nix`/`nixos-install` command
> below needs `--extra-experimental-features 'nix-command flakes'`, or export
> `export NIX_CONFIG="experimental-features = nix-command flakes"` once at the start of your
> installer shell so you don't have to repeat the flag.

### vm only: create the VM first

Before booting the installer, create the VM itself (virt-manager or `virt-install`), with:
- **UEFI firmware** (OVMF) — required, since `vm` uses `systemd-boot` + disko's ESP, not GRUB.
- A **virtio disk** — this is what shows up as `/dev/vda` inside the guest, which
  `hosts/vm/disko.nix` targets directly (no device path to confirm, unlike the framework
  hosts on real hardware).
- A **virtiofs filesystem device** sharing this repo's directory from the host, with mount
  tag **`share`** (must match exactly — it's what `fileSystems."/home/ato/nixos-config"` in
  `profiles/vm-guest.nix` expects). In virt-manager: Add Hardware → Filesystem → Driver
  `virtiofs`, source path = your clone of this repo on the host, mount tag = `share`. This
  also requires the VM's memory to use shared memory backing (virt-manager sets this up
  automatically when you add a virtiofs device on a recent enough libvirt/QEMU).

Boot the official NixOS ISO as the VM's install media, then continue below the same as any
other host, using `.#vm`.

### All hosts

1. **Boot the installer** and connect to the network (`nmtui` for Wi-Fi, or plug in ethernet).

2. **Get this flake onto the installer:**
   ```sh
   nix-shell -p git --run 'git clone <this-repo-url> nixos-config'
   cd nixos-config
   ```

3. **Fill in the host-specific TODOs before partitioning anything** (framework hosts only —
   `vm`'s device path and git identity are already fixed, nothing to fill in):
   - `hosts/<host>/disko.nix` — the `device` field is a placeholder (`/dev/nvme0n1` for
     framework-work, `/dev/nvme1n1` for framework-personal). Confirm the real disk with
     `lsblk` or `ls -la /dev/disk/by-id/` and update it — prefer a `by-id` path, it's stable
     across boots and reorderings.
   - `hosts/<host>/settings.nix` — has a placeholder `git.userEmail`; update it (and
     `git.userName`) if you want your git identity baked into the system config.

   Replace `<host>` with `framework-work`, `framework-personal`, or `vm` throughout the rest
   of these steps.

4. **Partition, LUKS-encrypt, format, and mount via disko:**
   ```sh
   sudo nix --extra-experimental-features 'nix-command flakes' \
     run github:nix-community/disko -- --mode disko --flake .#<host>
   ```
   This reads `hosts/<host>/disko.nix`, creates the GPT + ESP layout, LUKS-encrypts the main
   partition (**you'll be prompted to set the LUKS passphrase here** — nothing is stored in
   this repo), formats btrfs, creates the `root`/`home`/`nix`/`swap` subvolumes (plus
   `libvirt` on the framework hosts), and mounts everything under `/mnt`.

5. **Install:**
   ```sh
   sudo nixos-install --flake .#<host> --root /mnt
   ```
   No root or user password is set declaratively anywhere in this repo, so
   `nixos-install` will prompt you to set the root password interactively. After first
   boot, log in as root and run `passwd <your-username>` to set a password for the
   primary user (its account is created by `hostConfig.user`, but with no password until
   you set one).

6. **Reboot, remove the install media.** You'll be prompted for the LUKS passphrase (set in
   step 4) before `/` can unlock and boot continues.

7. **Ongoing rebuilds** go through `./nixos-config.sh <host>` (a thin wrapper around
   `nixos-rebuild switch --flake path:.#<host>`) from then on — see below.

## Building / testing without touching real hardware

```sh
nix flake check --no-build              # fast: evaluate every module/host
nix build .#nixosConfigurations.<host>.config.system.build.toplevel --dry-run
```

`vm` is the only host you can iterate on from a dev machine (via libvirt) day-to-day; once
it's installed (see above — it needs the same disko install flow as the framework hosts now,
just on the VM's virtio disk instead of real hardware), further changes are just
`./nixos-config.sh vm`. `framework-work`/`framework-personal` only ever go through the real
install flow above, since disko partitions a real disk.

## Day-to-day usage

```sh
./nixos-config.sh <host>                 # sudo nixos-rebuild switch --flake .#<host>
nix flake update                         # bump flake.lock (all inputs)
nix flake update <input>                 # bump a single input, e.g. nixpkgs
```

`<host>` is one of `framework-work`, `framework-personal`, `vm`.

## Repo layout

See [`AGENTS.md`](./AGENTS.md) for the full module/directory conventions this flake follows
(dendritic pattern, `hostConfig.*` options namespace, profile composition, gotchas around
vicinae/podman/disko, etc.).
