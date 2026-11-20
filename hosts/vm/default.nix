{ self, inputs, ... }: {
  flake.nixosConfigurations.vm = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = { inherit self inputs; };
    modules = [
      self.nixosModules.vmSettings
      self.nixosModules.vmGuestProfile
      self.nixosModules.vmDisk
      inputs.disko.nixosModules.disko
      inputs.nix-flatpak.nixosModules.nix-flatpak
      self.nixosModules.workProfile
    ];
  };
}
