{ self, ... }: {
  # Standard desktop shared by all hosts: compositor + shell, core GUI apps,
  # containers, flatpak and home-manager. noctalia (bar/shell) is installed
  # and autostarted entirely via home-manager (self.homeModules.noctalia,
  # wired in through homeBase below), same as vicinae.
  flake.nixosModules.desktopProfile = { ... }: {
    imports = [
      self.nixosModules.commonConfigs
      self.nixosModules.audio
      self.nixosModules.fonts
      self.nixosModules.portals
      self.nixosModules.networking

      # Compositor + shell
      self.nixosModules.niri
      self.nixosModules.thunar

      # Applications
      self.nixosModules.browsers
      self.nixosModules.terminals
      self.nixosModules.dev
      self.nixosModules.containers
      self.nixosModules.screenshot
      self.nixosModules.zsh

      # Flatpak mechanism (enable + flathub remote) + user dotfiles
      self.nixosModules.flatpakBase
      self.nixosModules.homeBase
    ];

    # Base Flatpak apps present on every desktop host. Host profiles append
    # host-specific apps to services.flatpak.packages (it merges).
    services.flatpak.packages = [
      "com.github.tchx84.Flatseal"
      "com.discordapp.Discord"
      "org.libreoffice.LibreOffice"
      "com.calibre_ebook.calibre"
      "com.rtosta.zapzap"
      "org.remmina.Remmina"
      "dev.zed.Zed"
    ];
  };
}
