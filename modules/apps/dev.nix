_: {
  flake.nixosModules.dev = { pkgs, config, ... }: {
    programs.virt-manager.enable = true;
    virtualisation.libvirtd.enable = true;

    # Needed for guest vTPM (e.g. Windows 11's TPM 2.0 requirement).
    virtualisation.libvirtd.qemu.swtpm.enable = true;

    users.users.${config.hostConfig.user.name}.extraGroups = [ "libvirtd" ];

    environment.systemPackages = with pkgs; [
      dbeaver-bin
      jetbrains-toolbox
      bruno
    ];
  };
}
