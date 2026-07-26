_: {
  # Seeds Vicinae's settings and snippets from the repo-tracked copies. Uses
  # cp -n so a live file that already exists (edited via Vicinae's own UI) is
  # never clobbered by a later rebuild -- this only matters for a fresh
  # profile/host. Use update-vicinae-config.sh to pull settings/snippets
  # changes made via the UI back into modules/vicinae/.
  flake.homeModules.vicinaeConfig = { config, lib, ... }: {
    home.activation.vicinaeConfigSeed = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      config_dir="${config.xdg.configHome}/vicinae"
      snippets_dir="${config.xdg.dataHome}/vicinae/snippets"
      run mkdir -p "$config_dir" "$snippets_dir"
      run cp -n ${./settings.json} "$config_dir/settings.json"
      run cp -n ${./snippets.json} "$snippets_dir/snippets.json"
    '';
  };
}
