{ self, inputs, ... }: {
  flake.nixosModules.thunar = { pkgs, lib, ... }: {
    programs.thunar.enable = true;
    programs.thunar.plugins = [ pkgs.thunar-volman ];
    programs.xfconf.enable = true;

    services.udisks2.enable = true;
    services.gvfs.enable = true;
  };

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

    xfconf.settings.thunar."misc-single-click" = false;

    xfconf.settings.thunar-volman = {
      "automount-drives/enabled" = true;
      "automount-media/enabled" = true;
    };

    # appended rather than managed by gtk.gtk3.bookmarks so bookmarks added from Thunar keep working
    home.activation.thunarDocumentsBookmark = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      bookmarks="${config.xdg.configHome}/gtk-3.0/bookmarks"
      entry="file://${config.home.homeDirectory}/Documents"
      run mkdir -p "$(dirname "$bookmarks")" "${config.home.homeDirectory}/Documents"
      if ! grep -q "^$entry\( \|$\)" "$bookmarks" 2>/dev/null; then
        echo "$entry" >> "$bookmarks"
      fi
    '';

    # Thunar's "Open Terminal Here" launches xfce4-terminal.desktop
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

    systemd.user.services.thunar-daemon = {
      Unit = {
        Description = "Thunar (background daemon, so thunar-volman reacts to hotplug even with no window open)";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "thunar --daemon";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
