_: {
  flake.nixosModules.tailscale = { config, ... }: {
    services.tailscale = {
      enable = true;
      extraUpFlags = [ "--operator=${config.hostConfig.user.name}" ];
    };
  };
}
