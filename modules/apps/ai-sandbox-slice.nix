_: {
  flake.homeModules.aiSandboxSlice = { pkgs, lib, ... }: {
    xdg.configFile."systemd/user/ai-sandbox.slice".text = ''
      [Slice]
      CPUWeight=20
      IOWeight=20
      MemoryHigh=4G
    '';

    home.activation.aiSandboxSlice = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${pkgs.systemd}/bin/systemctl --user daemon-reload || true
    '';
  };
}
