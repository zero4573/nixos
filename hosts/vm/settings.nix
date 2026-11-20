_: {
  flake.nixosModules.vmSettings = { ... }: {
    hostConfig = {
      hostName = "ato-vm";
      user.name = "ato";
      user.description = "ato";
      profile = "work";
    };
  };
}
