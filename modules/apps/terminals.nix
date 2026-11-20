_: {
  flake.nixosModules.terminals = { pkgs, ... }: {
    environment.systemPackages = with pkgs; [
      alacritty
    ];
  };

  flake.homeModules.terminals = _: {
    programs.alacritty = {
      enable = true;
      settings = {
        window.opacity = 0.95;
        font.size = 11.0;
        scrolling.history = 10000;
        colors.selection = {
          background = "#f9e2af";
          text = "#1e1e2e";
        };
      };
    };
  };
}
