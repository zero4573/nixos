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
    };
  };
}
