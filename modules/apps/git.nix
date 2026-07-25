_: {
  # Renders hostConfig.git.identities (see hosts/options.nix) as git
  # conditional includes -- this module has no built-in notion of
  # "personal"/"work" or which forge is which, it just maps over whatever
  # list a host's settings.nix provides.
  #
  # Relies on programs.git.includes writing to ~/.config/git/config (XDG
  # path), which git only reads when ~/.gitconfig does *not* exist -- true on
  # this system today (the base identity/rebase settings live in
  # /etc/gitconfig via the NixOS-level programs.git in hosts/common.nix, a
  # separate mechanism). If anything ever creates ~/.gitconfig, git stops
  # reading ~/.config/git/config and these includeIf blocks go dark.
  flake.homeModules.git = { osConfig, lib, ... }: {
    programs.git.includes = lib.pipe osConfig.hostConfig.git.identities [
      (map (identity:
        let
          # Built as one attrset (not three separately-merged `user = {...}`
          # blocks) -- `//` is a shallow merge, so `{ user.name = ...; } //
          # { user.email = ...; }` would clobber `name` entirely rather than
          # combining them.
          user = lib.optionalAttrs (identity.userName != "") { name = identity.userName; }
            // lib.optionalAttrs (identity.userEmail != "") { email = identity.userEmail; }
            // lib.optionalAttrs (identity.signingKey != "") { signingKey = identity.signingKey; };
        in {
          condition = identity.condition;
          contents = lib.optionalAttrs (user != { }) { inherit user; }
            // lib.optionalAttrs (identity.signingKey != "") {
              gpg.format = "ssh";
              commit.gpgsign = true;
            };
        }))
      # Load-bearing, not just tidiness: home-manager's programs.git.includes
      # submodule only auto-generates `path` from `contents` when `contents
      # != {}` -- `path` has no default otherwise, so an entry with empty
      # contents and no explicit path throws an eval error when rendered,
      # not a silent no-op. This is what actually implements "if none are
      # provided, don't set a user/signingkey".
      (lib.filter (i: i.contents != { }))
    ];
  };
}
