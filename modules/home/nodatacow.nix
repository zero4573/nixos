_: {
  # Marks selected per-user data directories nodatacow (chattr +C).  Used for
  # things like SQLite db's that have frequent writes and don't need COW as
  # it would force a full re-journal of the file on each update
  #
  # NOTE: chattr +C only affects files created AFTER it's set on a
  # directory.  This can be forced by moving the db's and re-copying them
  # back.  THIS MUST BE A COPY, moving the file back will retain its attr
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
