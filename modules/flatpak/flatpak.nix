_: {
  # Flatpak mechanism shared by every desktop host: enable the service and add
  # flathub. Which packages get installed is set by profiles (they append to
  # services.flatpak.packages, which merges).
  flake.nixosModules.flatpakBase = { ... }: {
    services.flatpak.enable = true;

    services.flatpak.remotes = [{
      name = "flathub";
      location = "https://flathub.org/repo/flathub.flatpakrepo";
    }];
  };
}
