_: {
  # TODO: Zscaler Client Connector isn't in nixpkgs (proprietary .deb/.rpm): package the admin portal's installer
  # with autoPatchelfHook or buildFHSEnv, plus its systemd service and NetworkManager integration.
  flake.nixosModules.zscaler = { ... }: {
  };
}
