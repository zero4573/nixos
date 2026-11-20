_: {
  flake.nixosModules.users = { config, ... }:
  let
    user = config.hostConfig.user;
  in {
    users.users.${user.name} = {
      isNormalUser = true;
      description = if user.description != "" then user.description else user.name;
      extraGroups = user.extraGroups;
      initialPassword = user.initialPassword;
    };
  };
}
