_: {
  # Declarative btrfs + LUKS layout for the vm host, mirroring the framework
  # hosts' disk layout (see hosts/framework-*/disko.nix) so the vm matches
  # framework-work as closely as possible. /dev/vda is the standard qemu
  # virtio-blk root disk, so unlike the framework hosts there's no real
  # device path to confirm here.
  flake.nixosModules.vmDisk = { ... }: {
    disko.devices.disk.main = {
      type = "disk";
      device = "/dev/vda";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            type = "EF00";
            size = "1G";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          luks = {
            size = "100%";
            content = {
              type = "luks";
              name = "cryptroot-vm";
              settings.allowDiscards = true;
              content = {
                type = "btrfs";
                extraArgs = [ "-f" ];
                subvolumes = {
                  "/root" = {
                    mountpoint = "/";
                    mountOptions = [ "compress=zstd" "noatime" ];
                  };
                  "/home" = {
                    mountpoint = "/home";
                    mountOptions = [ "compress=zstd" "noatime" ];
                  };
                  "/nix" = {
                    mountpoint = "/nix";
                    mountOptions = [ "compress=zstd" "noatime" ];
                  };
                  "/swap" = {
                    mountpoint = "/.swap";
                    swap.swapfile.size = "4G";
                  };
                };
              };
            };
          };
        };
      };
    };
  };
}
