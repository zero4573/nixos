_: {
  flake.nixosModules.godot = { pkgs, ... }: {
    environment.systemPackages = [ pkgs.godot_4_7 ];
  };
}
