{ self, inputs, ... }: {
  flake.nixosModules.vmConfiguration = { pkgs, lib, ... }: {
    imports = [
      self.nixosModules.commonConfigs
      self.nixosModules.vmHardware
      self.nixosModules.niri
      self.nixosModules.thunar
    ];

    services.xserver.videoDrivers = [ "virtio" ];

    services.gnome.gnome-keyring.enable = true;

    # Bootloader.
    boot.loader.grub.enable = true;
    boot.loader.grub.device = "/dev/vda";
    boot.loader.grub.useOSProber = true;

    networking.hostName = "nixos"; # Define your hostname.

    security.sudo.extraRules = [{
      users = [ "ato" ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }];

    services.pulseaudio.enable = false;
    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      # If you want to use JACK applications, uncomment this
      #jack.enable = true;

      # use the example session manager (no others are packaged yet so this is enabled by default,
      # no need to redefine it in your config for now)
      #media-session.enable = true;
    };

    # Define a user account. Don't forget to set a password with ‘passwd’.
    users.users."ato" = {
      isNormalUser = true;
      description = "ato";
      extraGroups = [ "networkmanager" "wheel" ];
      #packages = with pkgs; [];
    };
    nixpkgs.config.allowUnfree = true;

    # Mount shared directory from host system
    virtualisation.libvirtd.enable = true;
    virtualisation.libvirtd.qemu.vhostUserPackages = [ pkgs.virtiofsd ];
    services.qemuGuest.enable = true;

    virtualisation.vmVariant.Virtualisation.SharedDirectories = [
      {
        source = "shared";
        target = "/home/ato/nixos-config";
      }
    ];

    fileSystems."/home/ato/nixos-config" = {
      device = "share";
      fsType = "virtiofs";
      options = [ "nofail" "x-systemd.automount" ];
    };
  };
}