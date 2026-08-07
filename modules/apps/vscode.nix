_: {
  flake.nixosModules.vscode = { pkgs, ... }: {
    environment.systemPackages = [
      pkgs.vscode
    ];
  };
}
