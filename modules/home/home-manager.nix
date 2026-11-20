{ self, inputs, ... }: {
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
        asdfVersions = config.programs.asdf.versions;
      };
      users.${user} = {
        imports = [
          self.homeModules.desktopHome
          self.homeModules.noctalia
          inputs.tix.homeModules.obsidianVaults
          self.homeModules.vicinaeConfig
          self.homeModules.terminals
          self.homeModules.browsers
          self.homeModules.thunar
          self.homeModules.mpd
          self.homeModules.zsh
          self.homeModules.nodatacow
          self.homeModules.git
          self.homeModules.diffnav
          self.homeModules.zed
          self.homeModules.claudeCode
          self.homeModules.claudeSandbox
          self.homeModules.kiroSandbox
          self.homeModules.agents
          self.homeModules.npmSandbox
          self.homeModules.sandboxProxy
          self.homeModules.gitSshBroker
          self.homeModules.reviewBroker
          self.homeModules.aiSandboxSlice
          inputs.tix.homeModules.tix
          self.homeModules.tixSetup
        ];
      };
    };
  };
}
