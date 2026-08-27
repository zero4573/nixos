_: {
  flake.nixosModules.networking = { pkgs, ... }: {
    networking.networkmanager.enable = true;

    networking.networkmanager.plugins = [ pkgs.networkmanager-openvpn ];
    environment.systemPackages = [
      pkgs.openvpn
      pkgs.networkmanagerapplet
    ];

    # System-wide DNS over HTTPS: dnscrypt-proxy runs a local resolver on
    # 127.0.0.1:53 and forwards all lookups over DoH. 
    services.dnscrypt-proxy = {
      enable = true;
      settings = {
        listen_addresses = [ "127.0.0.1:53" ];
        ipv6_servers = false;
        dnscrypt_servers = false;
        doh_servers = true;
        require_dnssec = true;

        sources.public-resolvers = {
          urls = [
            "https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md"
            "https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md"
          ];
          cache_file = "public-resolvers.md";
          minisign_key = "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3";
        };
      };
    };

    # Route DNS through systemd-resolved rather than a flat static resolver,
    # so split-DNS keeps working: dnscrypt-proxy (127.0.0.1) is the global
    # default, but NetworkManager still hands resolved any DNS servers +
    # search domains a VPN (GlobalProtect, Tailscale, ...) pushes, and those
    # are used for that VPN's own domains (or as the full default, if the
    # VPN marks itself as such) while it's connected. Also sets
    # networking.networkmanager.dns = "systemd-resolved" itself.
    services.resolved.enable = true;

    # DNSSEC-validate lookups ourselves rather than just trusting dnscrypt-proxy's
    # chosen resolver to have done it. Global DNS= (dnscrypt-proxy, our non-VPN
    # path) is the only thing bound by this setting.  Per-link DNS servers get 
    # their own DNSSEC mode, defaulting to unset/inherited, "allow-downgrade" 
    # is used instead of a strict `true` because a hard failure mode
    # would take down ALL resolution the moment the upstream resolver has any
    # DNSSEC hiccup, and because it has a heuristic for detecting private/VPN
    # zones and skipping validation for those rather than hard-failing them.
    services.resolved.settings.Resolve.DNSSEC = "allow-downgrade";
  };
}
