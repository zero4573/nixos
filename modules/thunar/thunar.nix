{ self, inputs, ... }: {
  flake.nixosModules.thunar = { pkgs, lib, ... }: {
    programs.thunar.enable = true;
    programs.thunar.plugins = [ pkgs.thunar-volman ];
    programs.xfconf.enable = true;

    # udisks2 + gvfs give Thunar/thunar-volman a backend to detect and mount
    # removable USB drives/disks; thunar-volman (above) is what actually
    # reacts to hotplug events and triggers the automount (policy set via
    # xfconf below, in the home-manager module).
    services.udisks2.enable = true;
    services.gvfs.enable = true;
  };

  # Thunar is a GTK3 app with no session theme daemon under niri, so its
  # look is set via home-manager's gtk module: adw-gtk3 (dark) gives it the
  # modern libadwaita look, Papirus-Dark for icons, matching the system-wide
  # Bibata cursor (already installed, see modules/niri/niri.nix).
  flake.homeModules.thunar = { pkgs, ... }: {
    gtk = {
      enable = true;

      theme = {
        name = "adw-gtk3-dark";
        package = pkgs.adw-gtk3;
      };

      iconTheme = {
        name = "Papirus-Dark";
        package = pkgs.papirus-icon-theme;
      };

      cursorTheme = {
        name = "Bibata-Modern-Classic";
        package = pkgs.bibata-cursors;
      };

      gtk3.extraConfig.gtk-application-prefer-dark-theme = true;
      gtk4.extraConfig.gtk-application-prefer-dark-theme = true;
    };

    # Require a double-click to open files/enter folders (Thunar's own
    # default is already double-click; this pins it declaratively).
    xfconf.settings.thunar."misc-single-click" = false;

    # Auto-mount removable drives/media (USB sticks, external disks) as soon
    # as they're detected, without relying on thunar-volman's own first-run
    # defaults.
    xfconf.settings.thunar-volman = {
      "automount-drives/enabled" = true;
      "automount-media/enabled" = true;
    };

    # Thunar's "Open Terminal Here" shells out to `exo-open --launch
    # TerminalEmulator`, and this exo version has its Terminal Emulator
    # lookup hardcoded to the desktop id "xfce4-terminal.desktop" -- no
    # $TERMINAL check, no generic search. xfce4-terminal itself isn't
    # installed (alacritty is the only terminal on this system), so that
    # lookup fails with "Could not find fallback Terminal Emulator
    # Application". This shim satisfies the lookup by name while actually
    # launching alacritty; NoDisplay keeps it out of app launchers (vicinae
    # etc.) since it's not a real second terminal, just plumbing for exo.
    xdg.dataFile."applications/xfce4-terminal.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=Alacritty
      Comment=Terminal Emulator
      Exec=alacritty
      Icon=Alacritty
      Terminal=false
      Categories=System;TerminalEmulator;
      StartupNotify=true
      NoDisplay=true
    '';
  };
}
