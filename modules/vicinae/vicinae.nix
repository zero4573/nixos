_: {
  flake.homeModules.vicinaeConfig = { config, lib, pkgs, ... }: {
    home.activation.vicinaeConfigSeed = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      config_dir="${config.xdg.configHome}/vicinae"
      snippets_dir="${config.xdg.dataHome}/vicinae/snippets"
      run mkdir -p "$config_dir" "$snippets_dir"

      run cp -f ${./settings.json} "$config_dir/settings.json"
      run chmod u+w "$config_dir/settings.json"
      run cp -f ${./snippets.json} "$snippets_dir/snippets.json"
      run chmod u+w "$snippets_dir/snippets.json"

      run ${pkgs.systemd}/bin/systemctl --user try-restart vicinae.service
    '';
  };
}
