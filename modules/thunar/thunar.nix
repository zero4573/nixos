{ self, inputs, ... }: {
  flake.nixosModules.thunar = { pkgs, lib, ... }: {
    programs.thunar.enable = true;
    programs.thunar.plugins = [ pkgs.thunar-volman ];
    programs.xfconf.enable = true;

    # udisks2 + gvfs give Thunar/thunar-volman a backend to detect and mount
    # removable USB drives/disks
    services.udisks2.enable = true;
    services.gvfs.enable = true;
  };

  # Thunar theming
  flake.homeModules.thunar = { config, pkgs, lib, ... }: {
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

    dconf.settings."org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
      gtk-theme = "adw-gtk3-dark";
      icon-theme = "Papirus-Dark";
    };

    # Sets up double-click to open files/enter folders
    xfconf.settings.thunar."misc-single-click" = false;

    # Auto-mount removable drives/media (USB sticks, external disks) as soon
    # as they're detected
    xfconf.settings.thunar-volman = {
      "automount-drives/enabled" = true;
      "automount-media/enabled" = true;
    };

    # Adds ~/Documents to the Places side pane. Thunar reads its bookmarks
    # from gtk-3.0/bookmarks; the file is appended to rather than managed by
    # gtk.gtk3.bookmarks so bookmarks added from Thunar itself keep working.
    home.activation.thunarDocumentsBookmark = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      bookmarks="${config.xdg.configHome}/gtk-3.0/bookmarks"
      entry="file://${config.home.homeDirectory}/Documents"
      run mkdir -p "$(dirname "$bookmarks")" "${config.home.homeDirectory}/Documents"
      if ! grep -q "^$entry\( \|$\)" "$bookmarks" 2>/dev/null; then
        echo "$entry" >> "$bookmarks"
      fi
    '';

    # Hack to setup alacritty as the terminal when running "Open Terminal Here"
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

    # Autostart Thunar in daemon mode (no window) so hotplug
    # automount works even when no Thunar window is open.
    systemd.user.services.thunar-daemon = {
      Unit = {
        Description = "Thunar (background daemon, so thunar-volman reacts to hotplug even with no window open)";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        # Note: Need to use the thunar resolved in the path here as at this
        #       point its already added to the path
        ExecStart = "thunar --daemon";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
