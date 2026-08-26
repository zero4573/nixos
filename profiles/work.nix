{ self, ... }: {
  flake.nixosModules.workProfile = { pkgs, lib, config, ... }: {
    imports = [
      self.nixosModules.desktopProfile

      self.nixosModules.tailscale
      self.nixosModules.globalprotect
      self.nixosModules.teamviewer
      self.nixosModules.intune
      self.nixosModules.zscaler       # placeholder (not in nixpkgs)
      self.nixosModules.beyondtrust   # placeholder (not in nixpkgs)

      self.nixosModules.onepassword
    ];

    services.flatpak.packages = [
      "com.anydesk.Anydesk"
      "us.zoom.Zoom"
    ];

    environment.systemPackages = [
      pkgs.awscli2
      pkgs.cw
    ];

    programs.asdf.plugins = [
      "terraform"
      "packer"
    ];

    systemd.user.services.teams-pwa = {
      description = "Microsoft Teams (PWA)";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      environment = {
        TZ = "${config.hostConfig.timezone}";
        NIXOS_OZONE_WL = "1";
      };
      serviceConfig = {
        ExecStart = "${lib.getExe pkgs.chromium} --app=https://teams.microsoft.com/";
        Restart = "on-failure";
      };
    };

    programs.niri.extraBinds."Super+Shift+T".spawn-sh =
      ''TZ="${config.hostConfig.timezone}" ${lib.getExe pkgs.chromium} --app=https://teams.microsoft.com/'';

    systemd.user.services.joplin = {
      description = "Joplin";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" "teams-pwa.service" ];
      serviceConfig = {
        ExecStartPre = "${lib.getExe' pkgs.coreutils "sleep"} 2";
        ExecStart = "${lib.getExe pkgs.flatpak} run net.cozic.joplin_desktop";
        Restart = "on-failure";
      };
    };

    # 1Password SSH agent integration
    #
    # Note: To finish enabling this, you need to enable "Use the SSH agent" in
    # 1Password GUI, Settings > Developer, then add your SSH keys to it there
    home-manager.users.${config.hostConfig.user.name}.sshAuthSock = {
      enable = true;
      initialization.bash = ''export SSH_AUTH_SOCK="$HOME/.1password/agent.sock"'';
      systemd.socketProviderUnit = "default.target";
    };
  };
}
