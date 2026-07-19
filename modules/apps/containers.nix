_: {
  # Podman with Docker compatibility (provides the `docker` command + socket).
  flake.nixosModules.containers = { pkgs, config, ... }: {
    virtualisation.podman = {
      enable = true;
      dockerCompat = true;
      dockerSocket.enable = true;
      defaultNetwork.settings.dns_enabled = true;
    };

    # The docker-compat socket (and podman's own) is group-owned by "podman"
    # (systemd.sockets.podman.socketConfig.SocketGroup), not "docker" -- the
    # primary user needs to be in that group to access it without sudo.
    users.users.${config.hostConfig.user.name}.extraGroups = [ "podman" ];

    environment.systemPackages = with pkgs; [
      lazydocker
    ];
  };
}
