_: {
  # Joplin's Flathub manifest requests --filesystem=home (full home directory
  # access), which several community threads flag as overly broad for a note
  # app. Override it down to a dedicated folder under Documents; everything
  # else (network, notifications, wayland/x11, printing, tray icon, ...)
  # keeps the permissions from Joplin's own manifest.
  flake.nixosModules.joplin = { ... }: {
    services.flatpak.packages = [ "net.cozic.joplin_desktop" ];

    services.flatpak.overrides.settings."net.cozic.joplin_desktop".Context = {
      filesystems = [ "xdg-documents/Joplin:create" ];
    };
  };
}
