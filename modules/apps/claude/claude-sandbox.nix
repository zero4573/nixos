_: {
  flake.homeModules.claudeSandbox = { pkgs, lib, config, ... }:
  let
    cfg = config.programs.claudeSandbox;
    nestedPodmanEnv = pkgs.buildEnv {
      name = "claude-sandbox-nested-podman";
      paths = with pkgs; [
        podman
        podman-compose
        conmon
        crun
        netavark
        aardvark-dns
        catatonit
        slirp4netns
        iptables
      ];
    };

    gitUpdate = pkgs.writeShellScript "claude-git-update" ''
      export PATH=${lib.makeBinPath [ pkgs.git pkgs.coreutils ]}:$PATH
      ${builtins.readFile ./claude-git-update.sh}
    '';

    lspPlugin = pkgs.runCommand "claude-lsp-plugin" { } ''
      mkdir -p $out/.claude-plugin
      cp ${pkgs.writeText "plugin.json" (builtins.toJSON {
        name = "lsp";
        version = "1.0.0";
        description = "Language servers for Claude's LSP tool";
      })} $out/.claude-plugin/plugin.json
      cp ${pkgs.writeText "lsp.json" (builtins.toJSON cfg.lspServers)} $out/.lsp.json
    '';

    claudeOpen = pkgs.writeShellApplication {
      name = "claude-open";
      runtimeInputs = [ pkgs.jq pkgs.coreutils ];
      text = ''
        ${config.programs.agents.profileLib}
        agent_profile claude
        if [[ -n "''${AGENT_HOME:-}" ]]; then export CLAUDE_CONFIG_DIR="$AGENT_HOME"; fi
        ${gitUpdate} "$PWD"
        exec ${lib.getExe' cfg.package "claude"} --plugin-dir ${lspPlugin} "$@"
      '';
    };

    nestedPodmanSetup = pkgs.writeShellScript "claude-sandbox-nested-podman-setup"
      (builtins.readFile ./claude-sandbox-nested-podman-setup.sh);

    sandboxAllowRules = [
      "Bash(kill:*)" "Bash(pkill:*)" "Bash(killall:*)"
      "Bash(rm:*)" "Bash(rm -rf:*)" "Bash(rmdir:*)" "Bash(unlink:*)"
      "Bash(git push:*)"
    ];
    # Claude Code rules are globs with no exclusions: `--force*` would also deny --force-with-lease
    sandboxDenyRules = [
      "Bash(git push --force)" "Bash(git push --force *)" "Bash(git push -f:*)"
      "Bash(git push --delete:*)" "Bash(git push -d:*)" "Bash(git push --mirror:*)" "Bash(git push --prune:*)"
      "Bash(git push * --force)" "Bash(git push * --force *)" "Bash(git push * -f*)"
      "Bash(git push * --delete*)" "Bash(git push * -d *)"
      "Bash(git push * --mirror*)" "Bash(git push * --prune*)" "Bash(git push * +*)"
    ];
    selfCheckExpectedTools = [ "git" "jj" "ssh-keygen" "kill" "pkill" "killall" "rg" "jq" "nix" "pw-node" "playwright" "ffmpeg" ];

    browserFonts = pkgs.makeFontsConf {
      fontDirectories = with pkgs; [ dejavu_fonts liberation_ttf noto-fonts noto-fonts-color-emoji ];
    };
    playwrightBrowsers = pkgs.playwright-driver.browsers.override {
      withChromium = true;
      withFirefox = false;
      withWebkit = false;
      withFfmpeg = true;
    };
    browserEnv = ''
      export PLAYWRIGHT_BROWSERS_PATH=${playwrightBrowsers}
      export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true
      export FONTCONFIG_FILE=${browserFonts}
    '';
    browserTools = [
      (pkgs.writeShellApplication {
        name = "pw-node";
        runtimeInputs = [ ];
        text = browserEnv + ''
          export NODE_PATH=${pkgs.playwright-test}/lib/node_modules''${NODE_PATH:+:$NODE_PATH}
          exec ${pkgs.nodejs}/bin/node "$@"
        '';
      })
      (pkgs.writeShellApplication {
        name = "playwright";
        runtimeInputs = [ ];
        text = browserEnv + ''
          exec ${pkgs.playwright-test}/bin/playwright "$@"
        '';
      })
      (pkgs.writeShellApplication {
        name = "ffmpeg";
        runtimeInputs = [ ];
        text = ''
          export FONTCONFIG_FILE=${browserFonts}
          exec ${lib.getExe' pkgs.ffmpeg "ffmpeg"} "$@"
        '';
      })
      (pkgs.writeShellApplication {
        name = "ffprobe";
        runtimeInputs = [ ];
        text = ''
          exec ${lib.getExe' pkgs.ffmpeg "ffprobe"} "$@"
        '';
      })
      (pkgs.writeShellApplication {
        name = "agg";
        runtimeInputs = [ ];
        text = ''
          exec ${lib.getExe pkgs.asciinema-agg} --font-dir ${pkgs.dejavu_fonts}/share/fonts "$@"
        '';
      })
      pkgs.asciinema
      pkgs.tmux
    ];

    selfCheck = pkgs.writeShellApplication {
      name = "claude-sandbox-self-check";
      runtimeInputs = [ ];
      text = ''
        export SELF_CHECK_TOOLS=${lib.escapeShellArg (lib.concatStringsSep " " selfCheckExpectedTools)}
        export SELF_CHECK_RULES=${lib.escapeShellArg (builtins.toJSON sandboxAllowRules)}
        export SELF_CHECK_CONTAINER_MARKER=/run/.containerenv
        export SELF_CHECK_SETTINGS=/etc/claude-code/managed-settings.json
        export SELF_CHECK_NIX_SOCKET=/nix/var/nix/daemon-socket/socket
        export SELF_CHECK_JQ=${pkgs.jq}/bin/jq
        export SELF_CHECK_TIMEOUT=${pkgs.coreutils}/bin/timeout
        ${builtins.readFile ./claude-sandbox-self-check.sh}
      '';
    };

    baseDevTools = with pkgs; [
        git git-lfs
        coreutils findutils diffutils gnugrep gnused gawk patch less file
        which tree ripgrep fd jq yq-go bc
        gnutar gzip bzip2 xz zstd zip unzip
        procps psmisc util-linux lsof strace
        curl wget iproute2 netcat-openbsd dnsutils rsync
        gnumake
        # go build's cgo needs a C compiler on PATH
        gcc
        shellcheck
        jujutsu
        openssh
        # pkgs.nix, not config.nix.package: a home-manager module can't reach the system option without osConfig
        nix
    ] ++ browserTools;
    devToolsEnv = pkgs.buildEnv {
      name = "claude-sandbox-dev-tools";
      paths = baseDevTools ++ [ selfCheck ] ++ cfg.extraPackages;
    };

    extraMcpConfig = lib.optionalString (cfg.extraMcpServers != { })
      (toString (pkgs.writeText "claude-sandbox-extra-mcp.json"
        (builtins.toJSON { mcpServers = cfg.extraMcpServers; })));

    managedSettings = pkgs.writeText "claude-sandbox-managed-settings.json"
      (builtins.toJSON {
        permissions.allow = sandboxAllowRules;
        permissions.deny = sandboxDenyRules;
      });

    launcherInputs = [ pkgs.podman pkgs.systemd pkgs.xdg-dbus-proxy pkgs.coreutils pkgs.jq pkgs.git pkgs.gnused ];
    commonExports = ''
      export SANDBOX_IMAGE=${lib.escapeShellArg cfg.image}
      export NESTED_PODMAN_SETUP=${nestedPodmanSetup}
      export NESTED_PODMAN_ENV_BIN=${nestedPodmanEnv}/bin
      export NIX_DAEMON_SOCKET_DIR=/nix/var/nix/daemon-socket
      export ASDF_VM_BIN=${pkgs.asdf-vm}/bin
      export CLAUDE_GIT_UPDATE=${gitUpdate}
      export GIT_SSH_BROKER=${lib.getExe' config.programs.gitSshBroker.package "git-ssh-broker"}
      export GIT_SSH_BROKER_SSH=${lib.getExe' pkgs.openssh "ssh"}
      export GIT_SSH_BROKER_UPSTREAM_AGENT=${lib.escapeShellArg config.programs.gitSshBroker.upstreamAgent}
      export SANDBOX_SIGNING_KEYS=${lib.escapeShellArg (lib.concatStringsSep ":" config.programs.gitSshBroker.signingKeys)}
      export GIT_SSH_BROKER_REWRITABLE_BRANCHES=${lib.escapeShellArg (lib.concatStringsSep ":" config.programs.gitSshBroker.rewritableBranches)}
      export GIT_SSH_BROKER_IDENTITY_EMAILS=${lib.escapeShellArg (lib.concatStringsSep ":" config.programs.gitSshBroker.identityEmails)}
      export GIT_GLOBAL_IGNORE=${config.xdg.configFile."git/ignore".source}
      export GIT_GLOBAL_CONFIG=${config.xdg.configFile."git/config".source}
      export CACERT_BUNDLE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
      export HERDR_BIN=${lib.getExe pkgs.herdr}
    '';

    rb = config.programs.reviewBroker;
    kiroLauncher = lib.attrByPath [ "programs" "kiroSandbox" "commands" "sandbox" ] null config;
    reviewBrokerExports = lib.optionalString (rb.models != [ ] && kiroLauncher != null) ''
      export REVIEW_BROKER=${lib.getExe' rb.package "review-broker"}
      export REVIEW_BROKER_KIRO=${lib.getExe' kiroLauncher "kiro"}
      export REVIEW_BROKER_MODELS=${lib.escapeShellArg (lib.concatStringsSep ":" rb.models)}
      export REVIEW_BROKER_EFFORT=${lib.escapeShellArg rb.effort}
      export REVIEW_BROKER_MAX_PARALLEL=${toString rb.maxParallel}
      export REVIEW_BROKER_TIMEOUT=${lib.escapeShellArg rb.timeout}
    '';

    sandboxLauncher = name:
      assert lib.assertMsg
        (lib.all (p: !(lib.hasInfix ":" p)) cfg.readOnlyPaths)
        "programs.claudeSandbox.readOnlyPaths: no entry may contain ':'";
      pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = launcherInputs;
      text = ''
        export SANDBOX_AGENT=claude
        export SANDBOX_AS=${name}
        export SANDBOX_CONFIG_PASS_ENV=${lib.escapeShellArg (lib.concatStringsSep " " cfg.passEnv)}
        export SANDBOX_CONFIG_RO_PATHS=${lib.escapeShellArg (lib.concatStringsSep ":" cfg.readOnlyPaths)}
        export CLAUDE_CODE=${cfg.package}
        ${commonExports}
        export DEV_TOOLS_BIN=${devToolsEnv}/bin
        export MANAGED_SETTINGS=${managedSettings}
        ${reviewBrokerExports}
        export EXTRA_MCP_CONFIG=${lib.escapeShellArg extraMcpConfig}
        export CLAUDE_LSP_PLUGIN=${lspPlugin}
        ${config.programs.agents.profileLib}
        agent_profile claude
        # herdr identifies agents by the pane's foreground process names, and the real claude runs in the container
        exec -a claude bash ${./claude-sandbox.sh} "$@"
      '';
    };
  in {
    options.programs.claudeSandbox.package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.claude-code;
      defaultText = lib.literalExpression "pkgs.claude-code";
      description = "claude-code package run by claude (sandboxed), claude-sandbox and claude-open.";
    };

    options.programs.claudeSandbox.image = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/library/debian:trixie-20261104-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2";
      readOnly = true;
      description = "Pinned image claude-sandbox runs Claude in.";
    };
    options.programs.claudeSandbox.passEnv = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "TIX_*" ];
      description = "Names (globs) of host environment variables passed into the sandbox; SANDBOX_PASS_ENV at launch adds more.";
    };

    options.programs.claudeSandbox.readOnlyPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "~/.cache/some-tool/models" ];
      description = "Host paths mounted read-only in every sandbox session; ~ and $HOME are expanded at launch, missing paths skipped; SANDBOX_RO_PATHS (colon-separated) at launch adds more.";
    };

    options.programs.claudeSandbox.extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Packages whose bin/ is put on PATH inside claude-sandbox (reached through the read-only /nix/store mount).";
    };

    options.programs.claudeSandbox.extraMcpServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
      example = lib.literalExpression ''
        { foo = { command = lib.getExe pkgs.foo-mcp; args = [ "--stdio" ]; }; }
      '';
      description = "Extra stdio MCP servers (Claude Code mcpServers entries, by name) for every claude-sandbox session; their commands run inside the sandbox, so they must be /nix/store paths or tools on its PATH.";
    };

    options.programs.claudeSandbox.lspServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = {
        go = {
          command = lib.getExe pkgs.gopls;
          args = [ "serve" ];
          extensionToLanguage.".go" = "go";
        };
        typescript = {
          command = lib.getExe pkgs.typescript-language-server;
          args = [ "--stdio" ];
          extensionToLanguage = {
            ".ts" = "typescript";
            ".mts" = "typescript";
            ".cts" = "typescript";
            ".tsx" = "typescriptreact";
            ".js" = "javascript";
            ".mjs" = "javascript";
            ".cjs" = "javascript";
            ".jsx" = "javascriptreact";
          };
        };
        ruby = {
          command = lib.getExe pkgs.ruby-lsp;
          args = [ ];
          extensionToLanguage = { ".rb" = "ruby"; ".rake" = "ruby"; };
        };
        terraform = {
          command = lib.getExe' pkgs.terraform-ls "terraform-ls";
          args = [ "serve" ];
          extensionToLanguage = { ".tf" = "terraform"; ".tfvars" = "terraform-vars"; };
        };
        bash = {
          command = lib.getExe pkgs.bash-language-server;
          args = [ "start" ];
          extensionToLanguage = { ".sh" = "shellscript"; ".bash" = "shellscript"; };
        };
        yaml = {
          command = lib.getExe pkgs.yaml-language-server;
          args = [ "--stdio" ];
          extensionToLanguage = { ".yml" = "yaml"; ".yaml" = "yaml"; };
        };
        nix = {
          command = lib.getExe pkgs.nixd;
          args = [ ];
          extensionToLanguage.".nix" = "nix";
        };
        dart = {
          command = lib.getExe pkgs.dart;
          args = [ "language-server" "--protocol=lsp" ];
          extensionToLanguage.".dart" = "dart";
        };
        java = {
          command = lib.getExe' pkgs.jdt-language-server "jdtls";
          args = [ "--java-executable" (lib.getExe' pkgs.jdk21_headless "java") ];
          extensionToLanguage.".java" = "java";
        };
        python = {
          command = lib.getExe' pkgs.basedpyright "basedpyright-langserver";
          args = [ "--stdio" ];
          extensionToLanguage = { ".py" = "python"; ".pyi" = "python"; };
        };
      };
      description = "Language servers (Claude Code .lsp.json entries, by name) for the LSP tool in every claude and claude-open session.";
    };

    options.programs.claudeSandbox.shared = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      internal = true;
      readOnly = true;
      default = {
        script = ./claude-sandbox.sh;
        inherit commonExports launcherInputs baseDevTools gitUpdate;
      };
      description = "The sandbox launcher pieces kiro-sandbox reuses.";
    };

    options.programs.claudeSandbox.commands = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      internal = true;
      readOnly = true;
      default = { sandbox = sandboxLauncher "claude"; open = claudeOpen; };
      description = "The claude wrappers (sandboxed and open) the agent dispatcher runs.";
    };

    config.home.packages = [ (sandboxLauncher "claude") (sandboxLauncher "claude-sandbox") claudeOpen ];
  };
}
