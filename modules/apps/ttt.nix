{ self, ... }: {
  # ttt (terminal editor), from nixpkgs, plus its herdr plugin. The NixOS
  # module installs the package and adds the home module to the primary user.
  flake.nixosModules.ttt = { config, pkgs, ... }: {
    environment.systemPackages = [ pkgs.ttt ];
    home-manager.users.${config.hostConfig.user.name}.imports = [ self.homeModules.ttt ];
  };

  # herdr keeps its plugin registry in ~/.config/herdr, so the plugin is
  # registered with `herdr plugin link` on every activation, pointing at the
  # herdr-plugin/ directory of the same ttt release as the package. Linking
  # (unlike `herdr plugin install`) fetches nothing and runs no build step,
  # which would otherwise curl-install a second ttt.
  flake.homeModules.ttt = { lib, pkgs, ... }:
  let
    plugin = "${pkgs.ttt.src}/herdr-plugin";
    herdr = lib.getExe pkgs.herdr;
  in {
    home.activation.tttHerdrPlugin = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${herdr} plugin unlink ttt.editor >/dev/null 2>&1 || true
      run ${herdr} plugin link ${plugin} >/dev/null
    '';
  };
}
