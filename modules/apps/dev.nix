_: {
  flake.nixosModules.dev = { pkgs, config, ... }: {
    programs.virt-manager.enable = true;
    virtualisation.libvirtd.enable = true;

    virtualisation.libvirtd.qemu.swtpm.enable = true;

    virtualisation.libvirtd.qemu.vhostUserPackages = [ pkgs.virtiofsd ];

    users.users.${config.hostConfig.user.name}.extraGroups = [ "libvirtd" ];

    environment.systemPackages = with pkgs; [
      dbeaver-bin
      jetbrains-toolbox
      bruno
    ];
  };
}
