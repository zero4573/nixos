_: {
  flake.nixosModules.screenshot = { pkgs, ... }: {
    environment.systemPackages = [ pkgs.flameshot ];
  };
}
