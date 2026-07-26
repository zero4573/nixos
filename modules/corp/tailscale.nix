_: {
  flake.nixosModules.tailscale = { config, pkgs, lib, ... }: {
    services.tailscale = {
      enable = true;
      extraUpFlags = [ "--operator=${config.hostConfig.user.name}" ];
    };

    environment.systemPackages = [ pkgs.trayscale ];
    systemd.user.services.trayscale = {
      description = "Trayscale (tray icon for tailscaled)";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = "${lib.getExe pkgs.trayscale} --hide-window";
        Restart = "on-failure";
      };
    };
  };
}
