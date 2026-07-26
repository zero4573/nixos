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

    # 1Password's Go SDK (and presumably other language SDKs) locate the
    # desktop app's IPC shared library by os.Stat()-ing a hardcoded list of
    # FHS-style paths per OS -- see find1PasswordLibPath() in
    # onepassword-sdk-go/internal/shared_lib_core.go. On Linux that list is
    # /usr/bin/1password/, /opt/1Password/, and /snap/bin/1password/, none of
    # which exist on NixOS (everything lives under /nix/store). Without this,
    # any SDK-based tool using WithDesktopAppIntegration fails immediately
    # with "1Password desktop application not found", even with the app
    # running, signed in, and the CLI integration socket working fine --
    # this check is a pure filesystem path lookup, unrelated to whether the
    # app or its IPC socket are actually reachable.
    systemd.tmpfiles.rules = [
      "d /opt/1Password 0755 root root -"
      "L+ /opt/1Password/libop_sdk_ipc_client.so - - - - ${pkgs._1password-gui}/share/1password/libop_sdk_ipc_client.so"
    ];
  };
}
