{ self, inputs, ... }: {
  flake.nixosConfigurations.vm = inputs.nixpkgs.lib.nixosSystem {
    # system = self.nixosModules.commonConfig.system;

    modules = [
      self.nixosModules.vmConfiguration
    ];
  };
}