_: {
  flake.homeModules.mpd = { config, ... }: {
    services.mpd = {
      enable = true;
      musicDirectory = "${config.home.homeDirectory}/Music";

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
