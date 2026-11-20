{ self, ... }: {
  flake.nixosModules.personalProfile = { ... }: {
    imports = [
      self.nixosModules.desktopProfile
    ];
  };
}
