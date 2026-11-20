_: {
  flake.nixosModules.globalprotect = { pkgs, ... }: {
    environment.systemPackages = with pkgs; [
      gpclient
      openconnect
    ];
  };
}
