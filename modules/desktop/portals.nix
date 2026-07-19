_: {
  # XDG desktop portals — required for screen sharing, file pickers and for
  # Flatpak apps to talk to the host under a wlroots compositor like niri.
  flake.nixosModules.portals = { pkgs, ... }: {
    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
      config.common.default = [ "gtk" ];
    };
  };
}
