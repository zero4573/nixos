_: {
  flake.nixosModules.frameworkWorkSettings = { config, ... }:
  let
    home = "/home/${config.hostConfig.user.name}";
  in {
    hostConfig = {
      hostName = "ato-fw-work";
      user.name = "ato";
      user.description = "ato";
      profile = "work";

      git.userName = "Andy To";
      git.userEmail = "ato@streamsix.com";
      git.identities = [
        {
          condition = "hasconfig:remote.*.url:*github.com*/**";
          userName = "Andy To";
          userEmail = "andya.to@gmail.com";
          signingKey = "${home}/.ssh/private.pub";
        }
        {
          condition = "hasconfig:remote.*.url:*bitbucket.org*/**";
          userName = "Andy To";
          userEmail = "ato@streamsix.com";
          signingKey = "${home}/.ssh/work.pub";
        }
      ];
    };
  };
}
