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
  #   npm-sandbox's install scripts can't reach it). Anything running inside
  #   a claude-sandbox (the agent, a package install script, a nested
  #   container) can call it as you, so each token's scopes are the real limit:
  #   keep them read-only, but for ticket creation if you want it (below).
  #   - `sandbox-proxy mcp add <name> --url <url> --op-item <item> [--auth basic|bearer]`
  #     registers a remote streamable-HTTP MCP server (config, no secrets, in
  #     ~/.config/sandbox-proxy/mcp-servers.json). The 1Password item holds
  #     username (basic auth only) + password (token).
  #   - container mcp-proxy: caddy serving http://mcp-proxy:8080/<name>,
  #     injecting the Authorization header for each server.
  #   - Atlassian (Jira + Bitbucket Cloud + Confluence) via Rovo MCP:
  #       1. an org admin enables API-token auth (Admin -> Rovo -> Rovo MCP
  #          server -> Authentication)
  #       2. create a *scoped* Atlassian API token (id.atlassian.com ->
  #          Security -> API tokens -> "Create API token with scopes", apps
  #          Jira and Bitbucket) with only read:jira:agent-interface,
  #          search:jira:agent-interface, read:me, read:account and
  #          read:bitbucket:agent-interface, never write:bitbucket:agent-interface
  #          (Bitbucket stays read-only: code goes through git-ssh-broker,
  #          which refuses force pushes and deletes). Optionally add
  #          write:jira:agent-interface so sessions can create tickets
  #          (claude-tickets asks you to confirm the source and contents
  #          first); without it Jira stays read-only. (Rovo hides the tools
  #          a token has no scope for, an unscoped legacy token only gets
  #          Teamwork Graph tools, and
  #          without read:me / read:account every Jira call fails with
  #          "Failed to fetch accessible products: 401"). An org admin must
  #          also allow you to use API-token auth. Store it in a 1Password
  #          *Login* item titled `mcp.atlassian.com` (username = Atlassian
  #          email, password = token; an "API Credential" item won't do, its
  #          secret field isn't named password). The token's scopes are the
  #          only thing limiting what the sandboxed Claude can do as you.
  #       3. sandbox-proxy mcp add atlassian --url https://mcp.atlassian.com/v2/mcp --op-item mcp.atlassian.com
  #          (basic auth: base64 email:token, what Rovo expects for personal
  #          tokens; bearer is for service-account keys). The ticket
  #          workflow (claude-tickets, modules/apps/claude-tickets.nix) uses
  #          it as the `jira` source: sessions get it from the sandbox, and
  #          `ct sync` from `sandbox-proxy host-mcp-config` on 127.0.0.1.
  #
  # `sandbox-proxy start` (called by every sandbox launch) brings up whatever
  # is configured. All sandboxes share one set of proxy containers, so `start`
  # reuses ones already running with the same config: only missing or changed
  # containers are (re)created, and only then is 1Password read. That way a
  # new session never cuts off the others' in-flight requests. Concurrent
  # starts take turns (flock). `sandbox-proxy restart [registry|mcp]`
  # recreates them after rotating a credential in 1Password. See the script
  # at: `sandbox-proxy.sh`
  flake.homeModules.sandboxProxy = { pkgs, lib, config, ... }:
  let
    registryCaddyfile = pkgs.writeText "sandbox-proxy-registry-caddyfile" (builtins.readFile ./registry-caddyfile);

    sandboxProxy = pkgs.writeShellApplication {
      name = "sandbox-proxy";
      runtimeInputs = [ pkgs.podman pkgs.jq pkgs.gawk pkgs.coreutils pkgs.util-linux ];
      text = ''
        export REGISTRY_PROXY_CADDYFILE=${registryCaddyfile}
        export SANDBOX_PROXY_MCP_HOST_PORT=${toString config.programs.sandboxProxy.mcpHostPort}
        exec bash ${./sandbox-proxy.sh} "$@"
      '';
    };
  in {
    # Host loopback port of the MCP routes (sandbox-proxy host-mcp-config,
    # ~/.config/sandbox-proxy/mcp-host.json), for host tools that call the
    # MCP servers without a model
    options.programs.sandboxProxy.mcpHostPort = lib.mkOption {
      type = lib.types.port;
      default = 47180;
      description = "127.0.0.1 port the MCP proxy is published on.";
    };

    config.home.packages = [ sandboxProxy ];
  };
}
