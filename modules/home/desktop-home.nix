{ inputs, ... }: {
  # Shared per-user (home-manager) config for desktop hosts.
  flake.homeModules.desktopHome = { pkgs, lib, osConfig, ... }: {
    imports = [ inputs.vicinae.homeManagerModules.default ];

    home.stateVersion = osConfig.hostConfig.stateVersion;

    # Disable GTK's middle-click/primary-selection paste. niri's touchpad
    # tap-to-click maps a 3-finger tap to a middle-click, so
    # a stray triple-tap pastes the primary selection into whatever's
    # focused. There's no way to disable just that finger count, so this
    # disables primary-selection paste globally instead.
    dconf.settings."org/gnome/desktop/interface".gtk-enable-primary-paste = false;

    # Vicinae launcher daemon (autostarted via systemd user service).
    programs.vicinae = {
      enable = true;
      systemd.enable = true;
      systemd.autoStart = true;
    };
  };
}
