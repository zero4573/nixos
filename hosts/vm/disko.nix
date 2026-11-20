_: {
  flake.nixosModules.vmDisk = { ... }: {
    systemd.tmpfiles.rules = [
      "h /var/lib/libvirt/images - - - - +C"
      "h /var/lib/flatpak - - - - +C"
      "h /var/lib/containers - - - - +C"
    ];

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
                  "/libvirt" = {
                    mountpoint = "/var/lib/libvirt/images";
                    mountOptions = [ "noatime" ];
                  };
                  "/flatpak" = {
                    mountpoint = "/var/lib/flatpak";
                    mountOptions = [ "noatime" ];
                  };
                  "/containers" = {
                    mountpoint = "/var/lib/containers";
                    mountOptions = [ "noatime" ];
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
