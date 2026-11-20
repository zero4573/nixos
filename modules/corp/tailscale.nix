_: {
  flake.nixosModules.tailscale = { config, pkgs, lib, ... }: let
    inherit (pkgs) trayscale;
  in {
    services.tailscale = {
      enable = true;
      extraUpFlags = [ "--operator=${config.hostConfig.user.name}" ];
    };

    environment.systemPackages = [ trayscale ];
    systemd.user.services.trayscale = {
      description = "Trayscale (tray icon for tailscaled)";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = "${lib.getExe trayscale} --hide-window";
        Restart = "on-failure";
      };
    };
  };
}
