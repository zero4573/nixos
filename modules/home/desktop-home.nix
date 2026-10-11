_: {
  # Shared per-user (home-manager) config for desktop hosts.
  flake.homeModules.desktopHome = { pkgs, lib, osConfig, ... }: {
    home.stateVersion = osConfig.hostConfig.stateVersion;

    # Vicinae launcher daemon (autostarted via systemd user service). Uses
    # home-manager's built-in module and nixpkgs' package.
    programs.vicinae = {
      enable = true;
      systemd.enable = true;
      systemd.autoStart = true;
    };
  };
}
