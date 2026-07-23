_: {
  # Marks selected per-user data directories nodatacow (chattr +C) for apps
  # whose files are genuine, frequently-rewritten SQLite databases -- COW +
  # compression on small random-write DB files fragments badly, same
  # rationale as the /libvirt, /var/lib/flatpak, /var/lib/containers disko
  # subvolumes (hosts/*/disko.nix), just at the per-user layer since disko
  # subvolumes don't know the primary user's name.
  #
  # CAVEAT: chattr +C only affects files created AFTER it's set on a
  # directory -- it does not retroactively convert already-written extents.
  # On a fresh profile this is moot; on an existing one, affected databases
  # keep old COW extents until rewritten wholesale. This is a one-time,
  # opportunistic setting, not a guarantee for pre-existing data. chattr +C
  # doesn't require root for the user's own files (unlike +i/+a).
  flake.homeModules.nodatacow = { config, lib, pkgs, ... }:
  let
    dirs = [
      "${config.xdg.dataHome}/vicinae"
      "${config.xdg.dataHome}/mpd"
    ];
    chattr = lib.getExe' pkgs.e2fsprogs "chattr";
  in {
    home.activation.nodatacowDirs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${lib.concatMapStringsSep "\n" (dir: ''
        run mkdir -p "${dir}"
        run ${chattr} +C "${dir}"
      '') dirs}
    '';
  };
}
