_: {
  # Shared hardware + laptop quality/security baseline for the Framework hosts.
  # Per-host device paths and the disko layout live in each host's directory.
  #
  # NOTE: verify boot.kernelModules / initrd modules against a real
  # `nixos-generate-config` on the actual Framework hardware.
  flake.nixosModules.frameworkHardware = { lib, pkgs, ... }: {
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

    # EFI + systemd-boot (works with the disko ESP).
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    # Framework laptops are AMD on recent models; adjust for Intel boards.
    boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "thunderbolt" "usb_storage" "sd_mod" ];
    boot.kernelModules = [ "kvm-amd" ];

    # Firmware + updates.
    hardware.enableRedistributableFirmware = true;
    services.fwupd.enable = true;

    # SSD longevity + LUKS discard is set per-disk in the disko layout.
    services.fstrim.enable = true;

    # Compressed swap for laptops.
    zramSwap.enable = true;

    # Battery status/percentage over D-Bus (org.freedesktop.UPower) -- reads
    # /sys/class/power_supply itself, but nothing exposes it to user-session
    # apps without this running. Noctalia's battery widget (and bar widget
    # in general) is built entirely on Quickshell's UPower service binding,
    # so without this it silently detects no battery at all and hides the
    # widget (hideIfNotDetected in modules/noctalia/noctalia.json).
    services.upower.enable = true;

    # Basic firewall (tailscale manages its own interface rules).
    networking.firewall.enable = true;
  };
}
