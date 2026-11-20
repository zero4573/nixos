_: {
  flake.nixosModules.networking = { pkgs, lib, config, ... }:
  let
    userName = config.hostConfig.user.name;

    dohPrompt = pkgs.writeShellApplication {
      name = "doh-network-prompt";
      runtimeInputs = [ pkgs.libnotify pkgs.networkmanager pkgs.coreutils ];
      text = builtins.readFile ./doh-network-prompt.sh;
    };

    dohDispatch = pkgs.writeShellApplication {
      name = "doh-network-dispatch";
      runtimeInputs = [ pkgs.networkmanager pkgs.systemd pkgs.coreutils ];
      text = lib.replaceStrings [ "@nmDoHUser@" ] [ userName ] (
        builtins.readFile ./doh-network-dispatch.sh
      );
    };

    dohWaitReady = pkgs.writeShellApplication {
      name = "doh-wait-ready";
      runtimeInputs = [ pkgs.networkmanager pkgs.dnsutils pkgs.coreutils ];
      text = builtins.readFile ./doh-wait-ready.sh;
    };
  in {
    networking.networkmanager.enable = true;

    networking.networkmanager.plugins = [ pkgs.networkmanager-openvpn ];
    environment.systemPackages = [
      pkgs.openvpn
      pkgs.networkmanagerapplet
    ];

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
          cache_file = "/var/lib/dnscrypt-proxy/public-resolvers.md";
          minisign_key = "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3";
        };
      };
    };

    services.resolved.enable = true;

    services.resolved.settings.Resolve.DNSSEC = false;

    systemd.tmpfiles.rules = [ "d /var/lib/doh-network-choice 0775 root networkmanager -" ];

    networking.networkmanager.dispatcherScripts = [
      {
        source = "${dohDispatch}/bin/doh-network-dispatch";
        type = "basic";
      }
      {
        source = "${dohWaitReady}/bin/doh-wait-ready";
        type = "pre-up";
      }
    ];

    systemd.user.services."doh-network-prompt@" = {
      description = "Prompt for DNS-over-HTTPS on network %i";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${dohPrompt}/bin/doh-network-prompt %i";
      };
    };
  };
}
