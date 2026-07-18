{ self, inputs, ... }: {
  flake.nixosModules.niri = { pkgs, lib, ... }:
  let
    wallpaper = ../../assets/fairy-tail.jpg;
    custom-sddm-astronaut = pkgs.sddm-astronaut.override {
      embeddedTheme = "black_hole";

      themeConfig = {
        Background = "${wallpaper}";
        FormBackgroundColor = "#000000";
        HideLoginButton = "true";
      };
    };

  in {
    programs.niri = {
      enable = true;
      package = self.packages.${pkgs.stdenv.hostPlatform.system}.customNiri;
    };

    systemd.user.services.niri.enableDefaultPath = false;

    environment.systemPackages = with pkgs; [
      bibata-cursors
      custom-sddm-astronaut
    ];

    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;
      theme = "sddm-astronaut-theme";

      package = pkgs.kdePackages.sddm;
      extraPackages = with pkgs; [
        bibata-cursors
        custom-sddm-astronaut
        kdePackages.qtmultimedia
      ];
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
          "Super+F"."fullscreen-window" = {};
          "Super+return".spawn-sh = lib.getExe pkgs.alacritty;
          "Super+Q"."close-window" = {};
          "Super+S".spawn-sh = "${lib.getExe self'.packages.customNoctalia} ipc call launcher toggle";
        };
      };
    };
  };
}