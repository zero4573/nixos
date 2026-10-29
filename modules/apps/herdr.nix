{ self, ... }: {
  # herdr (terminal agent multiplexer), from nixpkgs. The NixOS module
  # installs the package and adds the home module to the primary user.
  flake.nixosModules.herdr = { config, pkgs, ... }: {
    environment.systemPackages = [ pkgs.herdr ];
    home-manager.users.${config.hostConfig.user.name}.imports = [ self.homeModules.herdr ];
  };

  # ~/.config/herdr/config.toml, declared here. No agent integration is
  # installed (`herdr integration install claude` is never run), and agent
  # sessions are not resumed after a server restart.
  flake.homeModules.herdr = { pkgs, ... }: {
    xdg.configFile."herdr/config.toml".source =
      (pkgs.formats.toml { }).generate "herdr-config.toml" {
        session.resume_agents_on_restore = false;
      };
  };
}
