_: {
  # Zed's settings.json, pinned declaratively (previously only a live,
  # unmanaged file). theme.mode stays "system" rather than hardcoding "dark"
  # -- it follows the same system-wide dark-mode signal set in
  # modules/thunar/thunar.nix (dconf color-scheme=prefer-dark), so Zed
  # tracks the one place that preference lives instead of drifting from it.
  flake.homeModules.zed = { ... }: {
    home.file.".config/zed/settings.json".source = ./zed-settings.json;
  };
}
