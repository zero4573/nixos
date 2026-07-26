_: {
  flake.homeModules.mpd = { config, ... }: {
    services.mpd = {
      enable = true;
      musicDirectory = "${config.home.homeDirectory}/Music";

      # Enables auto_update so we don't have to remember to refresh the
      # directory, and sets up a separate audio_output for mpd so we can
      # control the mpd volume separately
      extraConfig = ''
        auto_update "yes"

        audio_output {
          type      "pulse"
          name      "PipeWire"
          mixer_type "software"
        }
      '';
    };

    services.mpd-mpris.enable = true;

    programs.ncmpcpp.enable = true;
  };
}
