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
      # Native package, not Flatpak: Zed's Flatpak build re-execs its real
      # binary on the host via `flatpak-spawn --host` (it only uses the
      # sandbox as a distribution mechanism), which fails on NixOS since the
      # host has no FHS `/lib64/ld-linux-x86-64.so.2` -- only nixpkgs'
      # friendly stub-ld placeholder that explains why it can't run generic
      # dynamically-linked binaries.
      zed-editor
    ];
  };
}
