{ self, inputs, ... }: {
  flake.nixosConfigurations.framework-personal = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = { inherit self inputs; };
    modules = [
      self.nixosModules.frameworkPersonalSettings
      self.nixosModules.frameworkHardware
      self.nixosModules.frameworkPersonalDisk
      inputs.disko.nixosModules.disko
      inputs.nix-flatpak.nixosModules.nix-flatpak
      self.nixosModules.personalProfile
    ];
  };
}
