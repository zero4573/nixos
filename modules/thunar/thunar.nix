{ self, inputs, ... }: {
  flake.nixosModules.thunar = { pkgs, lib, ... }: {
    programs.thunar.enable = true;
    programs.xfconf.enable = true;
  };
}
