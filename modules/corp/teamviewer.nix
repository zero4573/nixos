_: {
  flake.nixosModules.teamviewer = { ... }: {
    services.teamviewer.enable = true;
  };
}
