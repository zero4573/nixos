{ self, inputs, ... }: {

  # disko (see hosts/vm/disko.nix) generates fileSystems.* and
  # boot.initrd.luks.devices.* for the root disk, so this module must NOT
  # also declare root/boot filesystems or swapDevices. The virtiofs share
  # mount lives in profiles/vm-guest.nix.
  flake.nixosModules.vmHardware = { config, lib, pkgs, modulesPath, ... }: {
    imports = [
      (modulesPath + "/profiles/qemu-guest.nix")
    ];

    boot.initrd.availableKernelModules = [ "ahci" "xhci_pci" "virtio_pci" "sr_mod" "virtio_blk" ];
    boot.initrd.kernelModules = [ ];
    boot.kernelModules = [ "kvm-amd" ];
    boot.extraModulePackages = [ ];

    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  };
}
