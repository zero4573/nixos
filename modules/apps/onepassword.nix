_: {
  # 1Password: package, tray autostart, and its quick-access keybind, all in
  # one place. Composed into workProfile, so it applies to framework-work and
  # the vm -- the profile == "work" guard below is a belt-and-suspenders
  # check so none of this activates if the module is ever pulled in from
  # somewhere else.
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
