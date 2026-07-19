_: {
  # Home-manager module: install plain pkgs.noctalia-shell (bar/notifications/
  # wallpaper/etc., no wrapper-modules needed) and autostart it via its own
  # systemd user service (same HM-managed-autostart pattern as vicinae).
  #
  # noctalia-shell reads NOCTALIA_SETTINGS_FILE natively (see its
  # Commons/Settings.qml) to locate settings.json, so pointing that env var at
  # a generated file is all that's needed to load noctalia.json's settings --
  # exactly what the wrapper-modules "settings-only" wrap mode did for us
  # under the hood, just without the extra dependency.
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

    # noctalia-shell keeps its wallpaper selection in a runtime cache file
    # (wallpapers.json under its cache dir), separate from settings.json, and
    # starts with that cache empty on a fresh profile. `defaultWallpaper` is
    # the fallback it uses for any screen with no per-screen override, so
    # seeding it here is what makes the fairy-tail wallpaper apply
    # automatically regardless of monitor names. Per-screen overrides can
    # still be set in noctalia.json's state.wallpapers.
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

    # Seed the wallpaper cache on activation; never clobber a cache the user
    # has since picked their own wallpaper into.
    home.activation.noctaliaWallpaperState = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      cache_dir="${config.xdg.cacheHome}/noctalia"
      run mkdir -p "$cache_dir"
      run cp -n ${wallpaperCacheSeed} "$cache_dir/wallpapers.json"
    '';
  };
}
