_: {
  flake.homeModules.git = { osConfig, config, lib, ... }:
  let
    signedIdentities = lib.filter (i: i.userEmail != "" && i.signingKey != "") osConfig.hostConfig.git.identities;
    allowedSignersFile = "${config.home.homeDirectory}/.ssh/allowed_signers";
  in {
    programs.git.enable = true;

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

    # Lets `git log --show-signature` (and `git verify-commit`) verify SSH
    # signatures locally -- signing itself doesn't need this, only
    # verification does.
    programs.git.settings.gpg.ssh.allowedSignersFile = allowedSignersFile;
    programs.git.settings.log.showSignature = true;

    home.activation.gitAllowedSigners = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p "$(dirname ${lib.escapeShellArg allowedSignersFile})"
      : > ${lib.escapeShellArg allowedSignersFile}
      ${lib.concatMapStringsSep "\n" (i: ''
        if [ -f ${lib.escapeShellArg i.signingKey} ]; then
          printf '%s ' ${lib.escapeShellArg i.userEmail} >> ${lib.escapeShellArg allowedSignersFile}
          cat ${lib.escapeShellArg i.signingKey} >> ${lib.escapeShellArg allowedSignersFile}
        fi
      '') signedIdentities}
    '';
  };
}
