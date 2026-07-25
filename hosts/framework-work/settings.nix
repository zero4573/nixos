_: {
  flake.nixosModules.frameworkWorkSettings = { ... }: {
    hostConfig = {
      hostName = "ato-fw-work";
      user.name = "ato";
      user.description = "ato";
      profile = "work";
      # TODO: set your git identity.
      git.userName = "Andy To";
      git.userEmail = "ato@streamsix.com";

      # Per-remote signing/identity overrides (see modules/apps/git.nix).
      # Both entries are inert until their signingKey TODO is filled in
      # (empty contents get filtered out entirely) -- do that once the
      # corresponding key has been added to 1Password's SSH agent (see
      # modules/apps/onepassword.nix).
      git.identities = [
        {
          condition = "hasconfig:remote.*.url:*github.com*";
          userName = "Andy To";
          userEmail = "andya.to@gmail.com";
          # TODO: paste your personal SSH public key here.
          signingKey = "";
        }
        {
          condition = "hasconfig:remote.*.url:*bitbucket.org*";
          userName = "Andy To";
          userEmail = "ato@streamsix.com";
          # TODO: paste your work SSH public key here.
          signingKey = "";
        }
      ];
    };
  };
}
