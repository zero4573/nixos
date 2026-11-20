_: {
  # Joplin's Flathub manifest requests --filesystem=home, overly broad for a note app
  flake.nixosModules.joplin = { ... }: {
    services.flatpak.packages = [ "net.cozic.joplin_desktop" ];

    services.flatpak.overrides.settings."net.cozic.joplin_desktop".Context = {
      filesystems = [ "xdg-documents/Joplin:create" ];
    };
  };
}
