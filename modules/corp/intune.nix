_: {
  # Microsoft Intune (device management / compliance). services.intune wires
  # up microsoft-identity-broker + intune-portal (systemd units, dbus, tmpfiles).
  flake.nixosModules.intune = { ... }: {
    services.intune.enable = true;
  };
}
