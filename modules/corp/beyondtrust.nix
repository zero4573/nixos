_: {
  # TODO: BeyondTrust Remote Support isn't in nixpkgs (proprietary; NixOS is a "non-standard configuration"):
  # package the appliance's Access Console / Jump Client with autoPatchelfHook or buildFHSEnv (libglvnd, GTK, ...).
  flake.nixosModules.beyondtrust = { ... }: {
  };
}
