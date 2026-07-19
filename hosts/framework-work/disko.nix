_: {
  # Declarative btrfs + LUKS full-disk-encryption layout for framework-work.
  # disko generates fileSystems.* and boot.initrd.luks.devices.* from this, so
  # the host hardware module must NOT also declare root/boot filesystems.
  #
  # TODO: confirm `device` on the real machine (lsblk / by-id path preferred).
  flake.nixosModules.frameworkWorkDisk = { ... }: {
    disko.devices.disk.main = {
      type = "disk";
      device = "/dev/nvme0n1";
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
              name = "cryptroot";
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
