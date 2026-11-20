{ self, ... }: {
  perSystem = { pkgs, ... }: {
    packages.mcp-guard = pkgs.buildGoModule {
      pname = "mcp-guard";
      version = "0.1.0";
      src = ./mcp-guard;
      vendorHash = null;
      env.CGO_ENABLED = "0";
      meta.mainProgram = "mcp-guard";
    };
  };

  flake.homeModules.sandboxProxy = { pkgs, lib, config, ... }:
  let
    mcpGuard = self.packages.${pkgs.stdenv.hostPlatform.system}.mcp-guard;
    mcpPolicies = pkgs.writeText "sandbox-proxy-mcp-policies.json"
      (builtins.toJSON config.programs.sandboxProxy.mcpPolicies);
    registryCaddyfile = pkgs.writeText "sandbox-proxy-registry-caddyfile" (builtins.readFile ./registry-caddyfile);

    sandboxProxy = pkgs.writeShellApplication {
      name = "sandbox-proxy";
      runtimeInputs = [ pkgs.podman pkgs.jq pkgs.gawk pkgs.coreutils pkgs.util-linux ];
      text = ''
        export REGISTRY_PROXY_CADDYFILE=${registryCaddyfile}
        export SANDBOX_PROXY_MCP_HOST_PORT=${toString config.programs.sandboxProxy.mcpHostPort}
        export MCP_GUARD=${lib.getExe mcpGuard}
        export MCP_POLICIES=${mcpPolicies}
        exec bash ${./sandbox-proxy.sh} "$@"
      '';
    };
  in {
    options.programs.sandboxProxy.mcpHostPort = lib.mkOption {
      type = lib.types.port;
      default = 47180;
      description = "127.0.0.1 port the MCP proxy is published on, for host tools that call the MCP servers without a model (sandbox-proxy host-mcp-config).";
    };

    options.programs.sandboxProxy.mcpPolicies = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          gatedTools = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Tools whose calls name an operation in arguments.name.";
          };
          allowOps = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Operations a gated tool may run from a sandbox.";
          };
        };
      });
      default.atlassian = {
        gatedTools = [ "executeWrite" "executeDestructive" ];
        allowOps = [
          "createBitbucketRepoPullRequest"
          "updateBitbucketRepoPullRequest"
          "addBitbucketRepoPullRequestComment"
          "updateBitbucketRepoPullRequestComment"
          "resolveBitbucketRepoPullRequestComment"
          "reopenBitbucketRepoPullRequestComment"
          "createBitbucketRepoPullRequestTask"
          "setBitbucketRepoPullRequestTaskState"
          "uploadAttachmentToJiraIssue"
        ];
      };
      description = "Per MCP server name (`sandbox-proxy mcp add <name>`): a call to one of gatedTools runs only when the operation in its arguments.name is in allowOps. A server with no entry isn't checked.";
    };

    config.home.packages = [ sandboxProxy ];
  };
}
