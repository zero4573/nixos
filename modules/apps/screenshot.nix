_: {
  # Screenshots are captured via flameshot, bound to niri's screenshot
  # hotkeys (see modules/niri/niri.nix), writing to ~/Pictures/Screenshots
  # and the clipboard. grim is flameshot's actual capture backend on
  # wlroots/niri (see the homeModule below for why it needs to be enabled).
  flake.nixosModules.screenshot = { pkgs, ... }: {
    environment.systemPackages = with pkgs; [
      flameshot
      grim
    ];
  };

  # Without this, flameshot falls back to the xdg-desktop-portal screenshot
  # method on wlroots compositors (niri included) and logs a warning telling
  # you to flip this on -- the portal path can also pop up an interactive
  # picker/permission dialog per capture, which defeats the point of a
  # scripted screenshot hotkey. useGrimAdapter makes it call grim directly.
  # disabledGrimWarning silences flameshot's own generic "grim may not work
  # on GNOME" caution, which fires on every grim-adapter capture regardless
  # of compositor -- niri is wlroots-based, exactly where grim is supported.
  flake.homeModules.screenshot = { ... }: {
    xdg.configFile."flameshot/flameshot.ini".text = ''
      [General]
      useGrimAdapter=true
      disabledGrimWarning=true
    '';
  };
}
