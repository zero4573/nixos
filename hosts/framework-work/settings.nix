_: {
  flake.nixosModules.frameworkWorkSettings = { ... }: {
    hostConfig = {
      hostName = "ato-fw-work";
      user.name = "ato";
      user.description = "ato";
      profile = "work";

      git.userName = "Andy To";
      git.userEmail = "ato@streamsix.com";
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
