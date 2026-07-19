{ self, inputs, ... }: {
  flake.nixosConfigurations.vm = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = { inherit self inputs; };
    modules = [
      # hostOptions is imported once via commonConfigs (desktopProfile chain);
      # importing it again here would double-declare the options.
      self.nixosModules.vmSettings
      self.nixosModules.vmGuestProfile
      self.nixosModules.vmDisk
      inputs.disko.nixosModules.disko
      inputs.nix-flatpak.nixosModules.nix-flatpak
      # Mirror framework-work's software profile.
      self.nixosModules.workProfile
    ];
  };
}
