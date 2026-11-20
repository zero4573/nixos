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

    # 1Password's SDKs find the desktop app's IPC library only at hardcoded FHS paths (find1PasswordLibPath in
    # onepassword-sdk-go: /usr/bin/1password/, /opt/1Password/, /snap/bin/1password/), else "desktop application not found"
    systemd.tmpfiles.rules = [
      "d /opt/1Password 0755 root root -"
      "L+ /opt/1Password/libop_sdk_ipc_client.so - - - - ${pkgs._1password-gui}/share/1password/libop_sdk_ipc_client.so"
    ];
  };
}
