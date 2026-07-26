_: {
  # Screenshots are captured via flameshot, bound to niri's screenshot
  # hotkeys (see modules/niri/niri.nix), writing to ~/Pictures/Screenshots
  # and the clipboard. Flameshot 14 dropped its old grim adapter entirely --
  # capture now always goes through xdg-desktop-portal (see
  # modules/desktop/portals.nix for the xdg-desktop-portal-gnome backend
  # niri needs for this), so grim itself is no longer a dependency.
  flake.nixosModules.screenshot = { pkgs, ... }: {
    environment.systemPackages = [ pkgs.flameshot ];
  };
}
