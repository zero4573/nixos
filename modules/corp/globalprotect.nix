_: {
  # GlobalProtect VPN. nixpkgs ships the OpenConnect-based CLI/GUI (`gpclient`)
  # rather than Palo Alto's proprietary client; it covers SAML/SSO logins.
  flake.nixosModules.globalprotect = { pkgs, ... }: {
    environment.systemPackages = with pkgs; [
      gpclient
      openconnect
    ];
  };
}
