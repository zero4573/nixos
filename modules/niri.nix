{ self, inputs, ... }: {
  flake.nixosModules.niri = { pkgs, lib, ... }: {
    programs.niri = {
      enable = true;
      package = self.packages.${pkgs.stdenv.hostPlatform.system}.customNiri;
    };
  };

  perSystem = { pkgs, lib, self', ... }: {
    packages.customNiri = inputs.wrapper-modules.wrappers.niri.wrap {
      inherit pkgs;

      settings = {
        spawn-at-startup = [
          (lib.getExe self'.packages.customNoctalia)
        ];

        xwayland-satellite.path = lib.getExe pkgs.xwayland-satellite;

        input.keyboard.xkb.layout = "us";
        layout.gaps = 5;
        binds = {
          "Super+return".spawn-sh = lib.getExe pkgs.alacritty;
          "Super+Q"."close-window" = {};
          "Super+S".spawn-sh = "${lib.getExe self'.packages.customNoctalia} ipc call launcher toggle";
        };
      };
    };
  };
}