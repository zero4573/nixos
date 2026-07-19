{ self, ... }: {
  # framework-personal software profile: standard desktop + Steam (flatpak).
  # ZapZap is already in the base flatpak set (present on all desktops).
  flake.nixosModules.personalProfile = { ... }: {
    imports = [
      self.nixosModules.desktopProfile
    ];

    services.flatpak.packages = [
      "com.valvesoftware.Steam"
    ];
  };
}
