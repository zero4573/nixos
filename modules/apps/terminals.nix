_: {
  # Alacritty as the default terminal. User-level config lives in
  # homeModules.terminals (below); the package is installed system-wide so
  # niri binds can resolve it via lib.getExe.
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
      };
    };
  };
}
