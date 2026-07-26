{ self, ... }: {
  flake.nixosModules.personalProfile = { ... }: {
    imports = [
      self.nixosModules.desktopProfile
    ];

    services.flatpak.packages = [
      "com.valvesoftware.Steam"
    ];
  };
}
