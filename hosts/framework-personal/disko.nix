_: {
  # Declarative btrfs + LUKS layout for framework-personal, which lives on a
  # SEPARATE physical disk from framework-work. A distinct LUKS mapper name
  # avoids any clash if both disks are ever present in the same machine.
  #
  # TODO: confirm `device` on the real machine (the personal disk, e.g. the
  # second NVMe / an expansion card).
  flake.nixosModules.frameworkPersonalDisk = { ... }: {
    disko.devices.disk.main = {
      type = "disk";
      device = "/dev/nvme1n1";
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
              name = "cryptroot-personal";
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
                  # VM disk images (libvirt/QEMU, see modules/apps/dev.nix) get
                  # their own nodatacow subvolume: COW + compression on huge
                  # sparse disk images tanks performance and fragments badly.
                  # nodatacow implies no compression, so compress is omitted.
                  "/libvirt" = {
                    mountpoint = "/var/lib/libvirt/images";
                    mountOptions = [ "noatime" "nodatacow" ];
                  };
                  "/swap" = {
                    mountpoint = "/.swap";
                    swap.swapfile.size = "16G";
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
