_: {
  flake.nixosModules.onepassword = { config, pkgs, lib, ... }: lib.mkIf (config.hostConfig.profile == "work") {
    programs._1password.enable = true;
    programs._1password-gui = {
      enable = true;
      polkitPolicyOwners = [ config.hostConfig.user.name ];
    };

    systemd.user.services.onepassword-autostart = {
      description = "1Password (tray)";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = "${lib.getExe pkgs._1password-gui} --silent";
        Restart = "on-failure";
      };
    };

    programs.niri.extraBinds."Super+P".spawn-sh = "1password --quick-access";
  };
}
