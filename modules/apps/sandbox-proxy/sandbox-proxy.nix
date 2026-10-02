_: {
  # Credential broker for the sandboxes (claude-sandbox, npm-sandbox): real
  # credentials are fetched from 1Password on the host and only ever handed
  # to proxy containers, which inject them into upstream requests. Sandboxes
  # get credential-free URLs on host-local podman networks.
  #
  # Two services, each on its own network so a sandbox only reaches what it
  # joined:
  #
  # * Package registries (network `sandbox-registry`, used by both sandboxes)
  #   A private Artifactory (npm-virtual/go-virtual/docker-virtual, one shared
  #   username+password).
  #   - `sandbox-proxy host-login <host> --npm-repo <repo> --go-repo <repo> --docker-repo <repo>`
  #     run once to set up the configuration for each tool. Credentials come
  #     from a 1Password item titled the Artifactory hostname
  #     (username+password fields).
  #   - containers:
  #     - registry-proxy: caddy reverse proxy, see registry-caddyfile
  #     - registry-cache: docker registry pull-through cache for images
  #     - npm-proxy: Verdaccio, an npm-registry proxy/cache for modules
  #
  # * MCP servers (network `sandbox-mcp`, joined by claude-sandbox only, so
  #   npm-sandbox's untrusted install scripts can't act as you through it)
  #   - `sandbox-proxy mcp add <name> --url <url> --op-item <item> [--auth basic|bearer]`
  #     registers a remote streamable-HTTP MCP server (config, no secrets, in
  #     ~/.config/sandbox-proxy/mcp-servers.json). The 1Password item holds
  #     username (basic auth only) + password (token).
  #   - container mcp-proxy: caddy serving http://mcp-proxy:8080/<name>,
  #     injecting the Authorization header for each server.
  #   - Atlassian (Jira + Bitbucket Cloud + Confluence) via Rovo MCP:
  #       1. an org admin enables API-token auth (Admin -> Rovo -> Rovo MCP
  #          server -> Authentication)
  #       2. create a *scoped, read-only* Atlassian API token; store it in
  #          1Password item `mcp.atlassian.com` (username = Atlassian email,
  #          password = token). The token's scopes are the only thing
  #          limiting what the sandboxed Claude can do as you.
  #       3. sandbox-proxy mcp add atlassian --url https://mcp.atlassian.com/v1/mcp --op-item mcp.atlassian.com
  #
  # `sandbox-proxy start` (called by the sandbox wrappers) brings up whatever
  # is configured. See the script at: `sandbox-proxy.sh`
  flake.homeModules.sandboxProxy = { pkgs, lib, ... }:
  let
    registryCaddyfile = pkgs.writeText "sandbox-proxy-registry-caddyfile" (builtins.readFile ./registry-caddyfile);

    sandboxProxy = pkgs.writeShellApplication {
      name = "sandbox-proxy";
      runtimeInputs = [ pkgs.podman pkgs.jq pkgs.gawk pkgs.coreutils ];
      text = ''
        export REGISTRY_PROXY_CADDYFILE=${registryCaddyfile}
        exec bash ${./sandbox-proxy.sh} "$@"
      '';
    };
  in {
    home.packages = [ sandboxProxy ];
  };
}
