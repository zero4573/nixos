{ self, ... }: {
  # framework-work software profile: standard desktop + corporate tooling.
  # Also imported by the vm host so the VM mirrors framework-work.
  flake.nixosModules.workProfile = { pkgs, lib, config, ... }: {
    imports = [
      self.nixosModules.desktopProfile

      # Corporate connectivity / remote access
      self.nixosModules.tailscale
      self.nixosModules.globalprotect
      self.nixosModules.teamviewer
      self.nixosModules.intune
      self.nixosModules.zscaler       # placeholder (not in nixpkgs)
      self.nixosModules.beyondtrust   # placeholder (not in nixpkgs)

      # Work apps (autostart + keybind live here; 1Password's are in its own
      # module, see modules/apps/onepassword.nix)
      self.nixosModules.onepassword
    ];

    # Work-only Flatpak apps, appended to the base list (services.flatpak.packages
    # merges).
    services.flatpak.packages = [
      "com.anydesk.Anydesk"
      "us.zoom.Zoom"
    ];

    # Work-only asdf plugins, appended to the base list (profiles/desktop.nix;
    # programs.asdf.plugins merges).
    programs.asdf.plugins = [
      "terraform"
      "packer"
    ];

    systemd.user.services.teams-pwa = {
      description = "Microsoft Teams (PWA)";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      environment.TZ = "Canada/Eastern";
      serviceConfig = {
        ExecStart = "${lib.getExe pkgs.chromium} --app=https://teams.microsoft.com/";
        Restart = "on-failure";
      };
    };

    programs.niri.extraBinds."Super+Shift+T".spawn-sh =
      ''TZ="Canada/Eastern" ${lib.getExe pkgs.chromium} --app=https://teams.microsoft.com/'';

    # 1Password SSH agent integration: wires $SSH_AUTH_SOCK into zsh *and*
    # the systemd user manager/D-Bus activation environment (via
    # home-manager's generic sshAuthSock module), so GUI apps launched from
    # niri (e.g. IntelliJ) see it too, not just shell-spawned processes. No
    # profile guard needed here -- workProfile itself is only ever composed
    # into work-profile hosts (framework-work, vm).
    #
    # Manual step, not automatable: in the 1Password GUI, Settings >
    # Developer > enable "Use the SSH agent", then add your SSH keys to it
    # there.
    home-manager.users.${config.hostConfig.user.name}.sshAuthSock = {
      enable = true;
      initialization.bash = ''export SSH_AUTH_SOCK="$HOME/.1password/agent.sock"'';
      # No nix-managed systemd unit provides this socket (1Password's own
      # GUI process does, via its autostart service in
      # modules/apps/onepassword.nix) -- default.target is a harmless
      # ordering point, just needs *some* valid unit name here.
      systemd.socketProviderUnit = "default.target";
    };
  };
}
