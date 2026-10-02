_: {
  # Brokers access to a private Artifactory (npm-virtual/go-virtual/docker-virtual,
  # one shared username+password) for claude-sandbox/npm-sandbox, so the
  # sandboxes themselves never hold the real credential.
  #
  # * `registry-proxy host-login <host> --npm-repo <repo> --go-repo <repo> --docker-repo <repo>`
  # run once on the host to setup the configuration for each tool.
  # Credentials are fetched from a 1Password item titled the Artifactory
  # hostname (username+password fields).
  #
  # * `registry-proxy start`
  # starts up to three named containers on the private, host-local-only
  # network (`sandbox-registry`),
  #  - registry-proxy is a caddy reverse proxy. see registry-proxy-caddyfile
  #    for more information
  #  - registry-cache is a docker registry, a docker registry proxy here to act
  #    as a local cache for images
  #  - npm-proxy is Verdaccio, a npm-registry proxy.  Mainly here to act as a
  #    local cache for modules
  #
  # See the script at: `registry-proxy.sh`
  flake.homeModules.registryProxy = { pkgs, lib, ... }:
  let
    caddyfile = pkgs.writeText "registry-proxy-caddyfile" (builtins.readFile ./registry-proxy-caddyfile);

    registryProxy = pkgs.writeShellApplication {
      name = "registry-proxy";
      runtimeInputs = [ pkgs.podman pkgs.jq pkgs.gawk pkgs.coreutils ];
      text = ''
        export REGISTRY_PROXY_CADDYFILE=${caddyfile}
        exec bash ${./registry-proxy.sh} "$@"
      '';
    };
  in {
    home.packages = [ registryProxy ];
  };
}
