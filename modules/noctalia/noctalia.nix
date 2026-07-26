_: {
  flake.homeModules.noctalia = { pkgs, lib, config, ... }:
  let
    assets = ../../assets;
    wallpaper = ../../assets/fairy-tail.jpg;
    noctaliaJson = builtins.fromJSON (builtins.readFile ./noctalia.json);

    settingsFile = pkgs.writeText "noctalia-settings.json" (builtins.toJSON (
      noctaliaJson.settings // {
        wallpaper = {
          enabled = true;
          directory = "${assets}";
        };
      }
    ));

    wallpaperCacheSeed = pkgs.writeText "noctalia-wallpapers-seed.json" (builtins.toJSON {
      wallpapers = noctaliaJson.state.wallpapers;
      defaultWallpaper = "${wallpaper}";
      usedRandomWallpapers = { };
    });
  in {
    home.packages = [ pkgs.noctalia-shell ];

    systemd.user.services.noctalia = {
      Unit = {
        Description = "Noctalia shell (bar, notifications, wallpaper)";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        Environment = "NOCTALIA_SETTINGS_FILE=${settingsFile}";
        ExecStart = lib.getExe pkgs.noctalia-shell;
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    home.activation.noctaliaWallpaperState = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      cache_dir="${config.xdg.cacheHome}/noctalia"
      run mkdir -p "$cache_dir"

      # Note: this skips if a wallpaper has already been explicitly set
      run cp -n ${wallpaperCacheSeed} "$cache_dir/wallpapers.json"
    '';
  };
}
