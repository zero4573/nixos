_: {
  flake.nixosModules.frameworkHardware = { lib, pkgs, ... }: {
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "thunderbolt" "usb_storage" "sd_mod" ];
    boot.kernelModules = [ "kvm-amd" ];

    hardware.enableRedistributableFirmware = true;
    services.fwupd.enable = true;
    services.fstrim.enable = true;
    zramSwap.enable = true;

    services.upower.enable = true;
    networking.firewall.enable = true;

    services.pipewire.wireplumber.extraConfig."51-framework-mic-fix" = {
      "device.profile.priority.rules" = [
        {
          matches = [ { "device.name" = "alsa_card.pci-0000_c1_00.6"; } ];
          actions.update-props.priorities = [ "HiFi (Mic1, Mic2, Speaker)" ];
        }
      ];
    };
  };
}
