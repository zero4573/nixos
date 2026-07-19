{ self, inputs, ... }: {
  flake.nixosConfigurations.framework-work = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = { inherit self inputs; };
    modules = [
      self.nixosModules.frameworkWorkSettings
      self.nixosModules.frameworkHardware
      self.nixosModules.frameworkWorkDisk
      inputs.disko.nixosModules.disko
      inputs.nix-flatpak.nixosModules.nix-flatpak
      self.nixosModules.workProfile
    ];
  };
}
