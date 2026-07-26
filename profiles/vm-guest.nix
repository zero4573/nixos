{ self, ... }: {
  flake.nixosModules.vmGuestProfile = { pkgs, config, ... }:
  let
    userName = config.hostConfig.user.name;
  in {
    imports = [
      self.nixosModules.vmHardware
    ];

    services.xserver.videoDrivers = [ "virtio" ];

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

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
