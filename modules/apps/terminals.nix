_: {
  # Alacritty as the default terminal. User-level config lives in
  # home-manager (desktopHome); the package is installed system-wide so niri
  # binds can resolve it via lib.getExe.
  flake.nixosModules.terminals = { pkgs, ... }: {
    environment.systemPackages = with pkgs; [
      alacritty
    ];
  };
}
