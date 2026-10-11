_: {
  # systemd user slice for every AI sandbox container (claude-sandbox pods,
  # their graphify sidecars, the ticket code-graph containers, npm-sandbox): podman places them
  # here through --cgroup-parent=aisandbox.slice.
  #  * CPUWeight/IOWeight: the desktop session wins under contention
  #  * MemoryHigh: past this, the slice is throttled and reclaimed
  #  * MemoryMax: a hard cap, the OOM killer acts inside the slice instead
  #    of the whole machine swapping
  #  * TasksMax: a runaway build or fork bomb can't exhaust the user's PIDs
  # Percentages are of physical RAM, so this works on any host.
  # No dash in the name: systemd nests `a-b.slice` under `a.slice`, but podman
  # assumes a --cgroup-parent slice sits directly under user@.service, so pod
  # starts fail ("Unit ...libpod_pod_<id>.slice was already loaded or has a
  # fragment file").
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
