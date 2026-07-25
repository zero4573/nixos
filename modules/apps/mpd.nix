_: {
  # Local music: MPD + ncmpcpp. MPD isn't MPRIS-native, so mpd-mpris bridges
  # it to D-Bus/MPRIS -- that's what makes noctalia's media widget/IPC (see
  # modules/niri/niri.nix's XF86Audio* binds) see and control it.
  flake.homeModules.mpd = { config, ... }: {
    services.mpd = {
      enable = true;
      musicDirectory = "${config.home.homeDirectory}/Music";
      # Rescan on changes (inotify) instead of only at mpd startup -- without
      # this, the library silently stays empty/stale if ~/Music didn't exist
      # yet the first time mpd started (as happened before it was populated).
      extraConfig = "auto_update yes";
    };

    services.mpd-mpris.enable = true;

    programs.ncmpcpp.enable = true;
  };
}
