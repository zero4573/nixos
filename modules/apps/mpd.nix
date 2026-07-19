_: {
  # Local music: MPD + ncmpcpp. MPD isn't MPRIS-native, so mpd-mpris bridges
  # it to D-Bus/MPRIS -- that's what makes noctalia's media widget/IPC (see
  # modules/niri/niri.nix's XF86Audio* binds) see and control it.
  flake.homeModules.mpd = { config, ... }: {
    services.mpd = {
      enable = true;
      musicDirectory = "${config.home.homeDirectory}/Music";
    };

    services.mpd-mpris.enable = true;

    programs.ncmpcpp.enable = true;
  };
}
