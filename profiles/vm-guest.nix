{ self, ... }: {
  # VM-specific hardware/virtualisation glue. Composed alongside a software
  # profile (workProfile) by the vm host so the VM mirrors framework-work.
  flake.nixosModules.vmGuestProfile = { pkgs, config, ... }:
  let
    userName = config.hostConfig.user.name;
  in {
    imports = [
      self.nixosModules.vmHardware
    ];

    services.xserver.videoDrivers = [ "virtio" ];

    # Bootloader: EFI + systemd-boot, same as the framework hosts (works with
    # disko's ESP partition; also lets NixOS's vm-variant tooling pick OVMF
    # firmware automatically).
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    # Host <-> guest tooling and shared directory. libvirtd itself is already
    # enabled via modules/apps/dev.nix (workProfile).
    virtualisation.libvirtd.qemu.vhostUserPackages = [ pkgs.virtiofsd ];
    services.qemuGuest.enable = true;

    virtualisation.vmVariant.Virtualisation.SharedDirectories = [
      {
        source = "shared";
        target = "/home/${userName}/nixos-config";
      }
    ];

    fileSystems."/home/${userName}/nixos-config" = {
      device = "share";
      fsType = "virtiofs";
      options = [ "nofail" "x-systemd.automount" ];
    };
  };
}
