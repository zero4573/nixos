_: {
  flake.nixosModules.calibre = { ... }: {
    services.flatpak.packages = [ "com.calibre_ebook.calibre" ];

    networking.firewall.allowedTCPPorts = [ 9091 ];
  };
}
