_: {
  flake.nixosModules.frameworkPersonalSettings = { ... }: {
    hostConfig = {
      hostName = "ato-fw-personal";
      user.name = "ato";
      user.description = "ato";
      profile = "personal";

      git.userName = "Andy To";
      git.userEmail = "andya.to@gmail.com";
    };
  };
}
