_: {
  # Developer / GUI tooling: database client, remote desktop, JetBrains
  # Toolbox and the virtual machine manager.
  flake.nixosModules.dev = { pkgs, config, ... }: {
    programs.virt-manager.enable = true;
    virtualisation.libvirtd.enable = true;

    # virt-manager needs the primary user in the libvirtd group.
    users.users.${config.hostConfig.user.name}.extraGroups = [ "libvirtd" ];

    environment.systemPackages = with pkgs; [
      dbeaver-bin
      jetbrains-toolbox
    ];
  };
}
