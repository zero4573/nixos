{
  description = "Main nix project for setting up my environments";

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

    # The ticket workflow (tix: commands, the plugin for Claude Code and
    # kiro, Obsidian vault setup),
    # its own repo (andy-ct on Bitbucket, fetched over ssh with your Bitbucket
    # key). See modules/apps/tix.nix. To try local changes
    # before pushing: --override-input tix
    # git+file:///home/ato/Projects/repo-work/bitbucket/streamsix/andy-ct
    tix = {
      url = "git+ssh://git@ssh.bitbucket.org/streamsix/andy-ct.git?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
