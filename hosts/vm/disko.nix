_: {
  # Declarative btrfs + LUKS layout for the vm host, mirroring the framework
  # hosts' disk layout (see hosts/framework-*/disko.nix) so the vm matches
  # framework-work as closely as possible. /dev/vda is the standard qemu
  # virtio-blk root disk, so unlike the framework hosts there's no real
  # device path to confirm here.
  flake.nixosModules.vmDisk = { ... }: {
    # btrfs's `compress`/`nodatacow` mount options are per-FILESYSTEM (shared
    # kernel state for the whole block device), not per subvolume -- since
    # /root mounts first with compress=zstd, a `nodatacow` mount option on a
    # sibling subvolume of the SAME device is silently ignored (confirmed via
    # `findmnt` showing compress=zstd applied instead of nodatacow). The only
    # way to actually get nodatacow on these subvolumes is the per-inode NOCOW
    # attribute (`chattr +C`), applied here via tmpfiles right after boot,
    # before anything writes to them.
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
                  # VM disk images (libvirt/QEMU, see modules/apps/dev.nix) get
                  # their own subvolume: COW + compression on huge sparse disk
                  # images tanks performance and fragments badly. nodatacow
                  # itself is enforced via chattr +C (see systemd.tmpfiles.rules
                  # above), not the mount option -- see the comment on this
                  # module for why.
                  "/libvirt" = {
                    mountpoint = "/var/lib/libvirt/images";
                    mountOptions = [ "noatime" ];
                  };
                  # Flatpak's OSTree repo + per-app deployments (nix-flatpak
                  # hardcodes installation = "system", so /var/lib/flatpak is
                  # the one that matters). Same nodatacow rationale as /libvirt.
                  "/flatpak" = {
                    mountpoint = "/var/lib/flatpak";
                    mountOptions = [ "noatime" ];
                  };
                  # Rootful podman storage (modules/apps/containers.nix:
                  # dockerCompat + dockerSocket target the system socket, so
                  # /var/lib/containers is the storage backend actually in
                  # play). Overlay/VFS storage churns small files heavily;
                  # same nodatacow rationale as /libvirt.
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
