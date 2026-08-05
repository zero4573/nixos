_: {
  flake.nixosModules.containers = { pkgs, config, ... }: {
    virtualisation.podman = {
      enable = true;
      dockerCompat = true;
      dockerSocket.enable = true;
      defaultNetwork.settings.dns_enabled = true;
    };

    virtualisation.containers.registries.settings.unqualified-search-registries = [ "docker.io" ];

    users.users.${config.hostConfig.user.name}.extraGroups = [ "podman" ];

    environment.systemPackages = with pkgs; [
      lazydocker
      podman-compose
    ];
  };
}
