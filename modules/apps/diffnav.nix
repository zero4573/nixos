_: {
  flake.homeModules.diffnav = { pkgs, ... }: {
    home.packages = [ pkgs.diffnav ];

    xdg.configFile."diffnav/config.yml".source = (pkgs.formats.yaml { }).generate "diffnav-config.yml" {
      ui = {
        theme = "catppuccin_mocha";
        icons = "nerd-fonts-full";
        hideHeader = true;
        fileTreeWidth = 36;
      };
    };
  };
}
