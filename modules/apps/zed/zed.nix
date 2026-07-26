_: {
  flake.nixosModules.zed = { pkgs, ... }: {
    environment.systemPackages = [
      pkgs.zed-editor
    ];
  };

  flake.homeModules.zed = { ... }: {
    home.file.".config/zed/settings.json".source = ./zed-settings.json;
  };
}
