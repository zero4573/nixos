_: {
  flake.nixosModules.tailscale = { config, ... }: {
    services.tailscale = {
      enable = true;
      # Let the primary user manage tailscale without sudo. Applied on `up`;
      # if you authenticate out-of-band you may need `tailscale set --operator`.
      extraUpFlags = [ "--operator=${config.hostConfig.user.name}" ];
    };
  };
}
