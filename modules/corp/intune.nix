_: {
  flake.nixosModules.intune = { ... }: {
    services.intune.enable = true;

    systemd.sockets.intune-daemon.wantedBy = [ "sockets.target" ];
    systemd.user.timers.intune-agent.wantedBy = [ "graphical-session.target" ];
  };
}
