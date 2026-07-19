_: {
  # Brave (default) + Chromium (alternative).
  flake.nixosModules.browsers = { pkgs, ... }: {
    environment.systemPackages = with pkgs; [
      brave
      chromium
    ];
  };
}
