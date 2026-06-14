{
  description = "Main nix project for setting up my environments";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    import-tree.url = "github:vic/import-tree";
    wrapper-modules.url = "github:BirdeeHub/nix-wrapper-modules";
  };

  outputs = inputs: inputs.flake-parts.lib.mkFlake
    { inherit inputs; }
    {
      systems = [ "x86_64-linux" ];
      imports = [ (inputs.import-tree ./modules) (inputs.import-tree ./hosts)];
    };
}
