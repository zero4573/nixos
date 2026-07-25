{ self, ... }: {
  # framework-work software profile: standard desktop + corporate tooling.
  # Also imported by the vm host so the VM mirrors framework-work.
  flake.nixosModules.workProfile = { pkgs, lib, ... }: {
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
  };
}
