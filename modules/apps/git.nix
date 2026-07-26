_: {
  flake.homeModules.git = { osConfig, lib, ... }: {
    programs.git.includes = lib.pipe osConfig.hostConfig.git.identities [
      (map (identity:
        let
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

      (lib.filter (i: i.contents != { }))
    ];
  };
}
