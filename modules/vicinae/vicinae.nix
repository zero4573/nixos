_: {
  flake.homeModules.vicinaeConfig = { config, lib, ... }: {
    home.activation.vicinaeConfigSeed = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      config_dir="${config.xdg.configHome}/vicinae"
      snippets_dir="${config.xdg.dataHome}/vicinae/snippets"
      run mkdir -p "$config_dir" "$snippets_dir"

      # Don't overwrite existing settings
      run cp -n ${./settings.json} "$config_dir/settings.json"
      run cp -n ${./snippets.json} "$snippets_dir/snippets.json"
    '';
  };
}
