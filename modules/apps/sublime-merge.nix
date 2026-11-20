_: {
  flake.nixosModules.sublimeMerge = { config, ... }: {
    services.flatpak.packages = [ "com.sublimemerge.App" ];

    services.flatpak.overrides.settings."com.sublimemerge.App".Context = {
      filesystems = [ "xdg-config/git:ro" "/nix/store:ro" "~/.ssh:ro" ];
      sockets = [ "ssh-auth" ];
    };

    home-manager.users.${config.hostConfig.user.name}.home.shellAliases = {
      sublime-merge = "flatpak run com.sublimemerge.App";
    };
  };
}
