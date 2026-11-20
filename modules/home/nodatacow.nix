_: {
  # chattr +C only affects files created after it's set: existing files must be copied back in, not moved
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
