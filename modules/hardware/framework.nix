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

    # The ALC285 codec's unsolicited jack-detect interrupt is occasionally
    # missed/coalesced, so a headphone plugged in before or during playback
    # can get stuck routed to the speaker until a fresh unplug/replug edge
    # re-triggers detection. Poll the jack pin every 1s instead of relying
    # solely on the interrupt -- standard workaround for this class of
    # Realtek ALC2xx jack-sense bug.
    boot.extraModprobeConfig = ''
      options snd_hda_intel jackpoll_ms=1000
    '';

  };
}
