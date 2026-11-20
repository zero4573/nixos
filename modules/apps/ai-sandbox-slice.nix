_: {
  # No dash in the name: systemd nests `a-b.slice` under `a.slice`, but podman assumes a --cgroup-parent
  # slice sits directly under user@.service, and pod starts fail
  flake.homeModules.aiSandboxSlice = { pkgs, lib, ... }: {
    xdg.configFile."systemd/user/aisandbox.slice".text = ''
      [Slice]
      CPUWeight=20
      IOWeight=20
      MemoryHigh=50%
      MemoryMax=70%
      MemorySwapMax=2G
      TasksMax=8192
    '';

    home.activation.aiSandboxSlice = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${pkgs.systemd}/bin/systemctl --user daemon-reload || true
    '';
  };
}
