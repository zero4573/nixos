_: {
  flake.homeModules.noctalia = { pkgs, lib, config, ... }:
  let
    assets = ../../assets;
    wallpaper = ../../assets/fairy-tail.jpg;
    noctaliaJson = builtins.fromJSON (builtins.readFile ./noctalia.json);

    settingsSeed = pkgs.writeText "noctalia-settings-seed.json" (builtins.toJSON (
      noctaliaJson.settings // {
        wallpaper = {
          enabled = true;
          directory = "${assets}";
        };
      }
    ));

    pluginsSeed = pkgs.writeText "noctalia-plugins-seed.json" (builtins.toJSON noctaliaJson.pluginRegistry);

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
        ExecStart = lib.getExe pkgs.noctalia-shell;
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    home.activation.noctaliaConfigSeed = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      config_dir="${config.xdg.configHome}/noctalia"
      cache_dir="${config.xdg.cacheHome}/noctalia"
      run mkdir -p "$config_dir" "$cache_dir"

      run cp -f ${settingsSeed} "$config_dir/settings.json"
      run chmod u+w "$config_dir/settings.json"
      run cp -f ${pluginsSeed} "$config_dir/plugins.json"
      run chmod u+w "$config_dir/plugins.json"

      run cp -f ${wallpaperCacheSeed} "$cache_dir/wallpapers.json"
      run chmod u+w "$cache_dir/wallpapers.json"

      run ${pkgs.systemd}/bin/systemctl --user try-restart noctalia.service
    '';
  };
}
