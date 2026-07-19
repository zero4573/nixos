{
  description = "Main nix project for setting up my environments";

  nixConfig = {
    extra-substituters = [ "https://vicinae.cachix.org" ];
    extra-trusted-public-keys = [
      "vicinae.cachix.org-1:1kDrfienkGHPYbkpNj1mWTr7Fm1+zcenzgTizIcI3oc="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    import-tree.url = "github:vic/import-tree";
    wrapper-modules.url = "github:BirdeeHub/nix-wrapper-modules";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-flatpak.url = "github:gmodena/nix-flatpak";

    # NOTE: vicinae ships its own cachix binary cache. Do NOT make it follow
    # our nixpkgs or we lose the cache and rebuild it (and Qt) from source.
    vicinae.url = "github:vicinaehq/vicinae";
  };

  outputs = inputs: inputs.flake-parts.lib.mkFlake
    { inherit inputs; }
    {
      systems = [ "x86_64-linux" ];
      imports = [
        (inputs.import-tree ./modules)
        (inputs.import-tree ./profiles)
        (inputs.import-tree ./hosts)
      ];

      # Shared nixpkgs instance for all perSystem outputs (wrapped packages etc.).
      # allowUnfree is needed because wrapped packages / niri binds reference unfree
      # apps (brave, chromium, jetbrains-toolbox) via lib.getExe.
      perSystem = { system, ... }: {
        _module.args.pkgs = import inputs.nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      };
    };
}
