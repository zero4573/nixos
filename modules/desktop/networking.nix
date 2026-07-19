_: {
  # NetworkManager for all desktop hosts (the primary user is in the
  # networkmanager group by default via hostConfig.user.extraGroups).
  flake.nixosModules.networking = { pkgs, ... }: {
    networking.networkmanager.enable = true;

    # OpenVPN client, available on every host (not just work). The NM plugin
    # lets .ovpn profiles be imported/managed from the NetworkManager applet.
    networking.networkmanager.plugins = [ pkgs.networkmanager-openvpn ];
    environment.systemPackages = [ pkgs.openvpn ];
  };
}
