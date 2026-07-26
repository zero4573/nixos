{ self, ... }: {
  flake.nixosModules.desktopProfile = { pkgs, ... }: {
    imports = [
      self.nixosModules.commonConfigs
      self.nixosModules.audio
      self.nixosModules.graphics
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
      self.nixosModules.zed

      self.nixosModules.flatpakBase
      self.nixosModules.homeBase
    ];

    services.flatpak.packages = [
      "com.github.tchx84.Flatseal"
      "com.discordapp.Discord"
      "org.libreoffice.LibreOffice"
      "com.calibre_ebook.calibre"
      "com.rtosta.zapzap"
      "com.sublimemerge.App"
    ];

    # Native packages when flatpak packages are failing for whatever reason
    environment.systemPackages = [
      pkgs.remmina
    ];

    programs.asdf.plugins = [
      "golang"
      "java"
      "python"
      "nodejs"
    ];
  };
}
