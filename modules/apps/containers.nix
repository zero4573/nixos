_: {
  flake.nixosModules.containers = { pkgs, config, ... }: {
    virtualisation.podman = {
      enable = true;
      dockerCompat = true;
      dockerSocket.enable = true;
      defaultNetwork.settings.dns_enabled = true;
    };

    users.users.${config.hostConfig.user.name}.extraGroups = [ "podman" ];

    environment.systemPackages = with pkgs; [
      lazydocker
    ];
  };
}
