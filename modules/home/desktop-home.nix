_: {
  flake.homeModules.desktopHome = { pkgs, lib, osConfig, ... }: {
    home.stateVersion = osConfig.hostConfig.stateVersion;

    programs.vicinae = {
      enable = true;
      systemd.enable = true;
      systemd.autoStart = true;
    };
  };
}
