# Desktop, hardware and host choices

Decisions in the desktop, hardware and host modules that the code doesn't say
by itself.

## Hosts (`hosts/common.nix`)

- IPv4 is preferred over IPv6 in address resolution (`getaddrinfo` precedence).
  `/etc/hosts` stays mutable, with a baseline written once.
- `systemd.oomd` kills cgroups under memory pressure (root and user slices)
  instead of letting the machine freeze (IntelliJ, containers and a browser at
  once). The trade-off: a runaway process can be killed abruptly.
- `e2fsprogs` is on PATH for `chattr`/`lsattr`.
- `modules/home/nodatacow.nix` marks per-user directories with frequently
  written SQLite databases `nodatacow`: copy-on-write would rewrite the whole
  file on each update.
- `hosts/framework-*/disko.nix`: check the `device` before running disko; it
  erases whatever drive it names.
- `flake.nix`'s shared `perSystem` nixpkgs sets `allowUnfree` because wrapped
  packages and niri binds reference unfree apps (brave, chromium,
  jetbrains-toolbox) through `lib.getExe`.

## Networking and DNS (`modules/desktop/networking/`)

- DNS goes through systemd-resolved so split DNS keeps working: dnscrypt-proxy
  (127.0.0.1, DoH only, `require_dnssec`) is the global default, while VPNs'
  (GlobalProtect, Tailscale) DNS servers and search domains, handed over by
  NetworkManager, serve their domains while connected.
- resolved's own DNSSEC is off on purpose. Validating twice roughly doubled
  per-query latency (extra DNSKEY/DS lookups, each paying the DoH round trip,
  measured), and `require_dnssec` already limits dnscrypt-proxy to validating
  resolvers.
- Each new WiFi or Ethernet network is asked once: force DoH, or use the
  network's own DNS. `doh-network-dispatch.sh` (a NetworkManager dispatcher hook,
  root) starts the user's `doh-network-prompt@` service on "up" of a connection
  not asked about yet. Answers persist in `/var/lib/doh-network-choice`, keyed by
  connection UUID; the directory is `root:networkmanager 0775` so the prompt
  writes its marker without sudo, before the reconnect, so the reconnect doesn't
  ask again.
- A declined, dismissed or timed-out (45s) prompt forces DoH, so a new network
  never silently stays on plaintext DNS.
- A connection forced onto DoH has dnscrypt-proxy as its only resolver, so
  `doh-wait-ready.sh` waits for it to answer before the connection comes up. It
  gives up after 10s and always exits 0, so a broken dnscrypt-proxy can't block
  networking.
- GlobalProtect is nixpkgs' OpenConnect-based `gpclient`, not Palo Alto's
  client; it handles SAML/SSO logins.

## niri (`modules/niri/niri.nix`)

- Workspace binds 1..9 follow CachyOS's niri keybinds (`Mod+N` focus,
  `Mod+Ctrl+N` move to); the vicinae clipboard and power binds are extras.
- `programs.niri.extraBinds` lets other modules add keybinds without niri.nix
  knowing them.
- Primary-selection paste is off, so a three-finger tap (middle click) doesn't
  paste.
- `Super+Escape` is the emergency escape: it drops any keyboard-shortcut
  inhibitor a fullscreen app holds.
- Alacritty is installed system-wide so niri binds resolve it through
  `lib.getExe`.

## Audio and Bluetooth (`modules/desktop/bluetooth.nix`)

- A Bluetooth sink becomes the default output on connect, or when an A2DP/HFP
  switch recreates it; on disconnect WirePlumber's fallback picks the next sink.
- The headset mic is deliberately not made the default: that flipped the
  headset to HFP on every call, and this Intel adapter's SCO link often errors
  right after, leaving calls silent. Picking the mic in an app still works.
- Chromium (Teams PWA) output streams are pinned to `target.object -1` so they
  follow the default sink; moving a stream by hand (pavucontrol) still works.
- mpd has `auto_update` on and its own `audio_output`, so its volume is separate.

## Noctalia (`modules/noctalia/`)

- Only the declarative baseline lives in `config.toml`; the rest is tweaked in
  the GUI. `update-noctalia-config.sh` pulls live GUI changes into `gui.toml`
  (tracked copy as base, live values winning) so they can be committed;
  wallpapers picked from the repo's assets are stored as `/nix/store` paths,
  which go stale once the assets change, hence its warning.
- The `cpu-power` service publishes CPU package power to `/run/cpu-power/watts`
  for the `sysmon_extra` `cpu_power` widget. The RAPL energy counter is root-only
  because high-rate reads leak power-based timing (CVE-2020-8694, "Platypus");
  a 2s average rounded to 0.1 W is far too coarse for that, so only this value
  is made world-readable. The service has only `CAP_DAC_READ_SEARCH`. The file
  keeps the history so a config reload redraws the full graph at once.
- The widget hides only when the watts file is missing (no RAPL zone, e.g. a VM);
  a one-off bad read keeps the last render. `disk_io` skips a rate after a gap
  over 10s (suspend), which would average minutes rather than the last interval.

## Other desktop pieces

- Thunar runs as a daemon so thunar-volman automounts hotplugged drives with no
  window open.
- `update-vicinae-config.sh` pulls live Vicinae settings and snippets into
  `modules/vicinae` with the repo copy as base and the live copy winning (jq `*`
  deep merge; snippets merged by id), so committed local-only tweaks survive.
- `modules/apps/zsh/cmd-timing.zsh` prints each command's start time and a
  `took <duration>` line in p10k's grey from plain preexec/precmd hooks.
- Joplin's filesystem access is narrowed to one folder under Documents.
- Flameshot 14 captures only through xdg-desktop-portal (`portals.nix`), so
  there is no grim.
- `godot_4_7` stays on the 4.7.x standard (non-.NET) build rather than nixpkgs'
  latest `godot`.
- libvirtd has `swtpm` (a vTPM for Windows 11) and `virtiofsd` (virtiofs shared
  folders).
- The 1Password SSH agent (`profiles/work.nix`) also needs "Use the SSH agent"
  enabled in the 1Password app (Settings > Developer) and the keys added there.

## mouse-debounce (`modules/hardware/mouse-debounce/`)

Fixes chatter from worn mouse switches: single clicks registering as double
clicks, and holds or drags that let go mid-click. The daemon grabs every
external mouse exclusively, re-emits its events through a virtual uinput
device, and holds each button release back 50ms; a release followed by a press
of the same button inside that window is dropped as a pair (both edge bounce and
a mid-hold dropout look like that). Motion and wheel events pass untouched.

- A mouse reports `REL_X` and `BTN_LEFT`; devices with `INPUT_PROP_BUTTONPAD`,
  an absolute axis, or "touchpad"/"trackpad" in the name are skipped, so a
  laptop's trackpad is never grabbed (`classifyDevice`). The daemon never grabs
  its own virtual device.
- It is hand-written against the evdev/uinput ioctls, standard library only,
  rather than a library or vendored tool, because it runs as root and grabs raw
  input; every line is auditable. The ioctl numbers are derived from the kernel's
  (dir, type, nr, size) tuples, and `TestIoctlConstants` checks them against a
  compiled C program.
- `/dev/input` is rescanned every 2s for plugged and unplugged devices.

## Sophos (`modules/corp/sophos.nix`)

SPL is installed per machine from the tenant's `SophosSetup.sh`, which embeds
registration credentials and is gitignored; never commit it. The module provides
what SPL expects: nix-ld (plus `libcap`, which SPL doesn't bundle), envfs for its
scripts' `/bin/bash` and `/usr/bin/*`, `/usr/sbin` symlinks for systemctl and
the shadow tools, and a declared `sophos-spl.service` (SPL can't write NixOS's
unit dirs) that does nothing until `/opt/sophos-spl` exists. SPL creates its own
`sophos-spl-*` users, which NixOS keeps since `users.mutableUsers` is on.

- Install: `sudo install -m 600 SophosSetup.sh /var/lib/sophos-spl-installer/`,
  then it installs on the next boot or switch (or `systemctl start
  sophos-spl-install`), or run `sudo sophos-install /path/to/SophosSetup.sh`.
  The installer directory is root-only (0700) and outside the world-readable
  store, since the installer carries the tenant's tokens.
  Success writes `/var/lib/sophos-spl-installer/installed`; the unit skips while
  the installer is missing or the marker exists.
- The install unit has `restartIfChanged = false` so a switch never interrupts
  it, a 30-minute start timeout for the download, and retries on the next boot.
- Check: `systemctl status sophos-spl-install sophos-spl`. Remove:
  `sudo /opt/sophos-spl/bin/uninstall.sh`, then delete the installer (or it
  reinstalls on boot) and the `installed` marker.
