_: {
  # PLACEHOLDER — BeyondTrust Remote Support is NOT in nixpkgs (proprietary
  # binary). NixOS is a "non-standard configuration" per BeyondTrust docs, so
  # packaging requires supplying the expected dependencies. To implement:
  #   1. Obtain the Linux Access Console / Jump Client from your BeyondTrust
  #      appliance.
  #   2. Package with autoPatchelfHook or buildFHSEnv, providing deps such as
  #      libglvnd (OpenGL), GTK, etc.
  # No-op until then so the work profile still evaluates.
  flake.nixosModules.beyondtrust = { ... }: {
  };
}
