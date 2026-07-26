_: {
  flake.nixosModules.networking = { pkgs, ... }: {
    networking.networkmanager.enable = true;

    networking.networkmanager.plugins = [ pkgs.networkmanager-openvpn ];
    environment.systemPackages = [
      pkgs.openvpn
      pkgs.networkmanagerapplet
    ];
  };
}
