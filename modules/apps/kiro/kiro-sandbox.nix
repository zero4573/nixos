_: {
  # kiro-cli, sandboxed the way Claude Code is (modules/apps/claude/claude-sandbox.nix):
  #
  #  * kiro - kiro-cli in a sandbox: the same launcher as claude
  #       (claude-sandbox.sh, with SANDBOX_AGENT=kiro), a privileged rootless
  #       podman container scoped to the current directory, with asdf tools,
  #       nested podman, the nix-daemon (untrusted users only), git over SSH
  #       and commit signing through git-ssh-broker, sandbox-proxy's
  #       registries and MCP servers, in aisandbox.slice. Every argument is
  #       kiro-cli's own (no arguments starts a chat); chats trust every
  #       tool (--trust-all-tools; the container is the boundary, as for
  #       claude's managed allow rules), SANDBOX_TRUST_ALL=0 to be
  #       asked. Sandbox settings are
  #       SANDBOX_* variables; `kiro-sandbox --help` lists them.
  #  * kiro-sandbox - the same command; its --help describes the sandbox.
  #  * kiro-open - the pinned kiro-cli (programs.kiroSandbox.openPackage,
  #       nixpkgs' FHS-wrapped build) unsandboxed, for tasks that need the
  #       host.
  #
  #  All three first bring a git checkout in the current directory up to
  #  date, as claude's do. A kiro-cli installed outside Nix (the upstream
  #  installer's ~/.local/bin/kiro-cli) is untouched: it stays unsandboxed
  #  and self-updating.
  #
  #  Where it differs from claude-sandbox: the host's ~/.kiro is never
  #  writable in the sandbox. kiro keeps workspace trust and "always allow"
  #  rules (~/.kiro/workspace-roots/), agents with hooks, MCP servers and
  #  settings there, which kiro-open on the host would act on; and kiro-cli
  #  extracts the runtimes it executes (bun, node, the agent server) into
  #  ~/.local/share/kiro-cli. So the sandbox has both of its own, in
  #  ~/.local/share/kiro-sandbox/{kiro,data}, with the host's agents,
  #  skills, steering, hooks and powers mounted read-only on top and a
  #  throwaway copy of ~/.kiro/settings (its mcp.json merged with
  #  sandbox-proxy's servers and programs.kiroSandbox.extraMcpServers). The
  #  login is the sandbox's own: a chat runs `kiro-cli login
  #  --use-device-flow` first when it isn't logged in. Sessions,
  #  history and trust given in the sandbox stay in the sandbox.
  #  There are no Claude-style path deny rules: what is read-write is the
  #  current directory and SANDBOX_ADD_DIRS.
  #
  #  kiro-cli comes from the flake's nixpkgs (kiro-cli-unwrapped in the
  #  container: the Debian image runs the bun it extracts as is; its glibc
  #  added to the binaries' RUNPATH, see kiroCliContainer), so it moves
  #  with `nix flake update`; see UPDATES.md.
  flake.homeModules.kiroSandbox = { pkgs, lib, config, ... }:
  let
    cfg = config.programs.kiroSandbox;
    shared = config.programs.claudeSandbox.shared;

    # Tools on the sandbox's PATH: claude-sandbox's base set (no
    # claude-sandbox-self-check: it checks Claude's managed settings), the
    # language servers kiro's code tool starts, and extraPackages
    devToolsEnv = pkgs.buildEnv {
      name = "kiro-sandbox-dev-tools";
      paths = shared.baseDevTools ++ cfg.lspPackages ++ cfg.extraPackages;
    };

    # kiro-cli-unwrapped for the container. Its loader is nixpkgs' glibc, but
    # its RUNPATH has no glibc, so libc.so.6 comes from the ld.so cache, and
    # nixpkgs' glibc reads /etc/ld.so.cache (its etc/ld.so.cache links
    # there). In the Debian image that cache lists Debian's glibc: the Nix
    # loader with Debian's libc segfaults before main (exit 139). RUNPATH is
    # searched before the cache, so add the loader's own glibc to it
    # (autoPatchelfHook's appendRunpaths: the hook runs after postFixup and
    # sets RUNPATH itself).
    kiroCliContainer = pkgs.kiro-cli-unwrapped.overrideAttrs (old: {
      appendRunpaths = (old.appendRunpaths or [ ]) ++ [ "${pkgs.stdenv.cc.libc}/lib" ];
    });

    extraMcpConfig = lib.optionalString (cfg.extraMcpServers != { })
      (toString (pkgs.writeText "kiro-sandbox-extra-mcp.json"
        (builtins.toJSON { mcpServers = cfg.extraMcpServers; })));

    # AGENT=<profile> (modules/apps/agents): a kiro profile's home is
    # KIRO_HOME, and its login (kiro-cli's data dir) is in <home>/.data
    # (kiro-cli reads XDG_DATA_HOME for it; tools the session runs see it
    # too)
    kiroOpen = pkgs.writeShellApplication {
      name = "kiro-open";
      runtimeInputs = [ pkgs.jq pkgs.coreutils ];
      text = ''
        ${config.programs.agents.profileLib}
        agent_profile kiro
        if [[ -n "''${AGENT_HOME:-}" ]]; then
          export KIRO_HOME="$AGENT_HOME" XDG_DATA_HOME="$AGENT_HOME/.data"
        fi
        ${shared.gitUpdate} "$PWD"
        exec ${lib.getExe' cfg.openPackage "kiro-cli"} "$@"
      '';
    };

    # SANDBOX_RO_PATHS and SANDBOX_ADD_DIRS are colon-separated,
    # so no readOnlyPaths entry may contain a colon
    sandboxLauncher = name:
      assert lib.assertMsg
        (lib.all (p: !(lib.hasInfix ":" p)) cfg.readOnlyPaths)
        "programs.kiroSandbox.readOnlyPaths: no entry may contain ':'";
      pkgs.writeShellApplication {
        inherit name;
        # find and grep read kiro's usage records for herdr (kiro_usage)
        runtimeInputs = shared.launcherInputs ++ [ pkgs.findutils pkgs.gnugrep ];
        text = ''
          export SANDBOX_AGENT=kiro
          export SANDBOX_AS=${name}
          # the configured lists; SANDBOX_PASS_ENV / SANDBOX_RO_PATHS in the
          # environment add to them
          export SANDBOX_CONFIG_PASS_ENV=${lib.escapeShellArg (lib.concatStringsSep " " cfg.passEnv)}
          export SANDBOX_CONFIG_RO_PATHS=${lib.escapeShellArg (lib.concatStringsSep ":" cfg.readOnlyPaths)}
          export KIRO_CLI=${cfg.package}
          ${shared.commonExports}
          export DEV_TOOLS_BIN=${devToolsEnv}/bin
          export EXTRA_MCP_CONFIG=${lib.escapeShellArg extraMcpConfig}
          # AGENT=<profile> (modules/apps/agents): AGENT_PROFILE / AGENT_HOME
          # for the launcher, which takes that home's config and login
          ${config.programs.agents.profileLib}
          agent_profile kiro
          # argv[0] kiro-cli, so a terminal multiplexer that identifies agents
          # by the pane's processes sees a kiro session
          exec -a kiro-cli bash ${shared.script} "$@"
        '';
      };
  in {
    options.programs.kiroSandbox = {
      package = lib.mkOption {
        type = lib.types.package;
        default = kiroCliContainer;
        defaultText = lib.literalMD "`pkgs.kiro-cli-unwrapped` with its glibc added to the binaries' RUNPATH";
        description = "kiro-cli run inside the sandbox (kiro, kiro-sandbox). Unwrapped: the container's Debian userland runs the generic-glibc runtimes kiro-cli extracts. Its binaries must find their own glibc through RUNPATH: otherwise they load the Debian image's libc and segfault.";
      };

      openPackage = lib.mkOption {
        type = lib.types.package;
        default = pkgs.kiro-cli;
        defaultText = lib.literalExpression "pkgs.kiro-cli";
        description = "kiro-cli run unsandboxed by kiro-open (nixpkgs' FHS-wrapped build, which runs on NixOS).";
      };

      passEnv = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "TIX_*" ];
        description = "Names (globs) of host environment variables passed into the kiro sandbox; SANDBOX_PASS_ENV in the environment adds more.";
      };

      readOnlyPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "~/.cache/some-tool/models" ];
        description = "Host paths mounted read-only in every kiro sandbox session; ~ and $HOME are expanded at launch, missing paths skipped. SANDBOX_RO_PATHS in the environment adds more.";
      };

      extraPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        description = "Packages whose bin/ is put on PATH inside the kiro sandbox (reached through the read-only /nix/store mount).";
      };

      # Their commands run inside the sandbox, so they must be /nix/store
      # paths (or tools on its PATH)
      extraMcpServers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
        default = { };
        example = lib.literalExpression ''
          { foo = { command = lib.getExe pkgs.foo-mcp; args = [ "--stdio" ]; }; }
        '';
        description = "Extra stdio MCP servers (kiro mcp.json mcpServers entries, by name) for every kiro sandbox session.";
      };

      # kiro's code tool (`/code init` writes the workspace's
      # .kiro/settings/lsp.json) starts language servers by command name:
      # its built-in configs use gopls, typescript-language-server,
      # pyright-langserver, solargraph, rust-analyzer, jdtls and clangd. The
      # rest are here for a workspace lsp.json to name (the servers
      # claude-sandbox gives Claude's LSP tool).
      lspPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = with pkgs; [
          gopls
          typescript-language-server
          pyright
          rubyPackages.solargraph
          ruby-lsp
          terraform-ls
          bash-language-server
          yaml-language-server
          nixd
        ];
        defaultText = lib.literalMD "gopls, typescript-language-server, pyright, solargraph, ruby-lsp, terraform-ls, bash-language-server, yaml-language-server, nixd";
        description = "Language servers on the kiro sandbox's PATH, for kiro's code tool.";
      };
    };

    config.home.packages = [ (sandboxLauncher "kiro") (sandboxLauncher "kiro-sandbox") kiroOpen ];
    # The commands modules/apps/agents' agent / agent-open run for a kiro
    # profile. Internal: not a setting.
    options.programs.kiroSandbox.commands = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      internal = true;
      readOnly = true;
      default = { sandbox = sandboxLauncher "kiro"; open = kiroOpen; };
      description = "The kiro wrappers (sandboxed and open) the agent dispatcher runs.";
    };
  };
}
