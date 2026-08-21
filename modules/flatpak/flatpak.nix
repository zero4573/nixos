_: {
  flake.nixosModules.flatpakBase = { config, ... }: {
    services.flatpak.enable = true;

    services.flatpak.remotes = [{
      name = "flathub";
      location = "https://flathub.org/repo/flathub.flatpakrepo";
    }];

    services.flatpak.overrides.settings.global.Environment.TZ = config.time.timeZone;
  };
}
