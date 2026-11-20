_: {
  flake.homeModules.kiroSandbox = { pkgs, lib, config, ... }:
  let
    cfg = config.programs.kiroSandbox;
    shared = config.programs.claudeSandbox.shared;

    devToolsEnv = pkgs.buildEnv {
      name = "kiro-sandbox-dev-tools";
      paths = shared.baseDevTools ++ cfg.lspPackages ++ cfg.extraPackages;
    };

    # Its loader is nixpkgs' glibc but its RUNPATH has none, so libc comes from /etc/ld.so.cache, which in the
    # Debian image lists Debian's glibc (segfault before main); autoPatchelfHook sets RUNPATH after postFixup
    kiroCliContainer = pkgs.kiro-cli-unwrapped.overrideAttrs (old: {
      appendRunpaths = (old.appendRunpaths or [ ]) ++ [ "${pkgs.stdenv.cc.libc}/lib" ];
    });

    extraMcpConfig = lib.optionalString (cfg.extraMcpServers != { })
      (toString (pkgs.writeText "kiro-sandbox-extra-mcp.json"
        (builtins.toJSON { mcpServers = cfg.extraMcpServers; })));

    # kiro-cli finds its data dir (the login) through XDG_DATA_HOME
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

    sandboxLauncher = name:
      assert lib.assertMsg
        (lib.all (p: !(lib.hasInfix ":" p)) cfg.readOnlyPaths)
        "programs.kiroSandbox.readOnlyPaths: no entry may contain ':'";
      pkgs.writeShellApplication {
        inherit name;
        runtimeInputs = shared.launcherInputs ++ [ pkgs.findutils pkgs.gnugrep ];
        text = ''
          export SANDBOX_AGENT=kiro
          export SANDBOX_AS=${name}
          export SANDBOX_CONFIG_PASS_ENV=${lib.escapeShellArg (lib.concatStringsSep " " cfg.passEnv)}
          export SANDBOX_CONFIG_RO_PATHS=${lib.escapeShellArg (lib.concatStringsSep ":" cfg.readOnlyPaths)}
          export KIRO_CLI=${cfg.package}
          ${shared.commonExports}
          export DEV_TOOLS_BIN=${devToolsEnv}/bin
          export EXTRA_MCP_CONFIG=${lib.escapeShellArg extraMcpConfig}
          ${config.programs.agents.profileLib}
          agent_profile kiro
          # herdr identifies agents by the pane's foreground process names
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

      extraMcpServers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
        default = { };
        example = lib.literalExpression ''
          { foo = { command = lib.getExe pkgs.foo-mcp; args = [ "--stdio" ]; }; }
        '';
        description = "Extra stdio MCP servers (kiro mcp.json mcpServers entries, by name) for every kiro sandbox session; their commands run inside the sandbox, so they must be /nix/store paths or tools on its PATH.";
      };

      # kiro's code tool starts servers by command name; its built-in configs use gopls,
      # typescript-language-server, pyright-langserver, solargraph, rust-analyzer, jdtls and clangd
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
    options.programs.kiroSandbox.commands = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      internal = true;
      readOnly = true;
      default = { sandbox = sandboxLauncher "kiro"; open = kiroOpen; };
      description = "The kiro wrappers (sandboxed and open) the agent dispatcher runs.";
    };
  };
}
