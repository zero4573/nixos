{ inputs, ... }: {
  # Shared per-user (home-manager) config for desktop hosts.
  flake.homeModules.desktopHome = { pkgs, lib, osConfig, ... }: {
    imports = [ inputs.vicinae.homeManagerModules.default ];

    home.stateVersion = osConfig.hostConfig.stateVersion;

    # Vicinae launcher daemon (autostarted via systemd user service).
    programs.vicinae = {
      enable = true;
      systemd.enable = true;
      systemd.autoStart = true;
    };
  };
}
