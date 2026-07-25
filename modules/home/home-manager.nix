{ self, inputs, ... }: {
  # Integrates home-manager as a NixOS module and points the primary user at
  # the shared desktop home config (flake.homeModules.desktopHome).
  flake.nixosModules.homeBase = { config, ... }:
  let
    user = config.hostConfig.user.name;
  in {
    imports = [ inputs.home-manager.nixosModules.home-manager ];

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      backupFileExtension = "hm-bak";
      extraSpecialArgs = {
        inherit self inputs;
        asdfPlugins = config.programs.asdf.plugins;
      };
      users.${user} = {
        imports = [
          self.homeModules.desktopHome
          self.homeModules.noctalia
          self.homeModules.thunar
          self.homeModules.screenshot
          self.homeModules.mpd
          self.homeModules.zsh
          self.homeModules.nodatacow
          self.homeModules.git
        ];
      };
    };
  };
}
