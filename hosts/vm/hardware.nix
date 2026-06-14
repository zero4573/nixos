{ self, inputs, ... }: {

  flake.nixosModules.vmHardware = { config, lib, pkgs, modulesPath, ... }: {
    imports = [
      (modulesPath + "/profiles/qemu-guest.nix")
    ];

    boot.initrd.availableKernelModules = [ "ahci" "xhci_pci" "virtio_pci" "sr_mod" "virtio_blk" ];
    boot.initrd.kernelModules = [ ];
    boot.kernelModules = [ "kvm-amd" ];
    boot.extraModulePackages = [ ];

    fileSystems."/" =
      { device = "/dev/disk/by-uuid/87a0a643-c8bc-41f2-9550-f9173ce8912f";
        fsType = "ext4";
      };

    fileSystems."/home/ato/nixos-config" =
      { device = "share";
        fsType = "virtiofs";
      };

    swapDevices = [ ];

    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  };
}
