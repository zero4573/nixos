_: {
  # Seeds Vicinae's snippets from the repo-tracked copy. Uses cp -n so a live
  # file that already exists (edited via Vicinae's own UI) is never clobbered
  # by a later rebuild -- this only matters for a fresh profile/host. Use
  # update-vicinae-snippets.sh to pull new snippets added via the UI back
  # into modules/vicinae/snippets.json.
  flake.homeModules.vicinaeSnippets = { config, lib, ... }: {
    home.activation.vicinaeSnippetsSeed = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      snippets_dir="${config.xdg.dataHome}/vicinae/snippets"
      run mkdir -p "$snippets_dir"
      run cp -n ${./snippets.json} "$snippets_dir/snippets.json"
    '';
  };
}
