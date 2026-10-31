_: {
  # Claude Code, sandboxed by default:
  #
  #  * claude - Claude Code in a sandbox (claude-sandbox.sh): a privileged
  #       rootless podman container scoped to the current directory, with asdf
  #       tools and its own nested podman. Every argument is claude's own and
  #       passes through untouched; what the session may touch follows
  #       Claude's settings (--add-dir and permissions.additionalDirectories
  #       mount read-write, Edit/Write deny rules inside them read-only).
  #       Sandbox-only settings are environment variables (SANDBOX_*, the
  #       same for kiro-sandbox: ports, pod name, quiet launch, host
  #       variables to pass in, more read-write directories, read-only host
  #       paths added to programs.claudeSandbox.readOnlyPaths);
  #       `claude-sandbox --help` lists them. Tools run through claude
  #       don't need to know they're sandboxed.
  #  * claude-sandbox - the same command, kept as an alias; its --help
  #       describes the sandbox rather than claude.
  #  * claude-open - the pinned claude-code (programs.claudeSandbox.package)
  #       unsandboxed, for tasks that need the host.
  #
  #  All three first bring a git checkout in the current directory up to date
  #  (claude-git-update.sh): fetch, then fast-forward the current branch to its
  #  upstream. Diverged branches or local changes in the way are reported and
  #  left alone; the launch always proceeds.
  #
  #  The sandbox joins the sandbox-proxy credential broker networks (see
  #  modules/apps/sandbox-proxy/sandbox-proxy.nix): `sandbox-registry` once
  #  `sandbox-proxy host-login` is configured, and `sandbox-mcp` once MCP
  #  servers were added with `sandbox-proxy mcp add` (e.g. Jira/Bitbucket via
  #  Atlassian Rovo), registered with claude without their tokens. The pod and
  #  its containers are named after the git repo + checkout folder
  #  (claude-sandbox-<repo>-<folder>[-N], with a -claude container suffix)
  #  and labelled claude-sandbox.{repo,project,role}, e.g.
  #  `podman ps --filter label=claude-sandbox.repo=<repo>`. Every session
  #  gets the stdio MCP servers in programs.claudeSandbox.extraMcpServers
  #  (none by default), and every session, claude-open's too, gets the
  #  language servers in programs.claudeSandbox.lspServers as a plugin for
  #  Claude's LSP tool. The sandbox's PATH
  #  gets programs.claudeSandbox.extraPackages. The containers run under the
  #  `aisandbox.slice` systemd user slice (see modules/apps/ai-sandbox-slice.nix)
  #  so they fair-share CPU/IO/memory with the rest of the desktop session.
  #  Each launch step is timestamped on stderr and logged to
  #  ~/.local/state/claude-sandbox.log, to see where a slow or stuck launch is.
  #
  #  Everything a session runs is pinned: claude-code comes from the flake's
  #  nixpkgs and the container image by digest. See UPDATES.md.
  #
  # Script bodies live in sibling files (claude-sandbox.sh,
  # claude-sandbox-nested-podman-setup.sh). claude-sandbox.sh also runs
  # kiro-cli (SANDBOX_AGENT=kiro, modules/apps/kiro/kiro-sandbox.nix), which
  # takes its agent-independent pieces from programs.claudeSandbox.shared.
  flake.homeModules.claudeSandbox = { pkgs, lib, config, ... }:
  let
    cfg = config.programs.claudeSandbox;
    # Toolchain for the NESTED podman running inside the sandbox container.
    # Built from the host's nixpkgs and reached through the read-only
    # /nix/store bind mount, so the container needs nothing preinstalled.
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

    # programs.claudeSandbox.lspServers as a Claude Code plugin (its
    # .lsp.json) that both launchers pass with --plugin-dir; the LSP tool it
    # backs is enabled by ENABLE_LSP_TOOL in claude-code.nix's settings
    lspPlugin = pkgs.runCommand "claude-lsp-plugin" { } ''
      mkdir -p $out/.claude-plugin
      cp ${pkgs.writeText "plugin.json" (builtins.toJSON {
        name = "lsp";
        version = "1.0.0";
        description = "Language servers for Claude's LSP tool";
      })} $out/.claude-plugin/plugin.json
      cp ${pkgs.writeText "lsp.json" (builtins.toJSON cfg.lspServers)} $out/.lsp.json
    '';

    # AGENT=<profile> (modules/apps/agents): a claude profile's home is
    # Claude's config dir (CLAUDE_CONFIG_DIR)
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

    # The allow rules of the managed settings below (kill commands, deleting
    # files, and git push: the launcher also drops the user settings' matching
    # denies, such as rm -rf and git push, in the container);
    # claude-sandbox-self-check compares the mounted file against this same
    # list, so they can't drift.
    sandboxAllowRules = [
      "Bash(kill:*)" "Bash(pkill:*)" "Bash(killall:*)"
      "Bash(rm:*)" "Bash(rm -rf:*)" "Bash(rmdir:*)" "Bash(unlink:*)"
      "Bash(git push:*)"
    ];
    # Pushes go through git-ssh-broker (modules/apps/git-ssh-broker), which
    # refuses force pushes and branch/tag deletes whatever the command line
    # says; these denies only make Claude stop and ask you to do them on the
    # host instead of trying. (A `:branch` refspec delete has no rule: `:*`
    # is the rules' prefix syntax. The broker refuses it all the same.)
    sandboxDenyRules = [
      "Bash(git push --force:*)" "Bash(git push -f:*)" "Bash(git push --force-with-lease:*)"
      "Bash(git push --delete:*)" "Bash(git push -d:*)" "Bash(git push --mirror:*)" "Bash(git push --prune:*)"
      "Bash(git push * --force*)" "Bash(git push * -f*)" "Bash(git push * --delete*)" "Bash(git push * -d *)"
      "Bash(git push * --mirror*)" "Bash(git push * --prune*)" "Bash(git push * +*)"
    ];
    # Commands the self-check expects on the sandbox PATH (devToolsEnv below)
    expectedTools = [ "git" "jj" "ssh-keygen" "kill" "pkill" "killall" "rg" "jq" "nix" ];

    # `claude-sandbox-self-check`: reports what a session has (see
    # claude-sandbox-self-check.sh). No runtimeInputs: PATH stays the
    # session's, so the tool checks are real; jq and timeout are called by
    # store path. Every input the script reads is exported here, so an
    # inherited SELF_CHECK_* can't fake a result.
    selfCheck = pkgs.writeShellApplication {
      name = "claude-sandbox-self-check";
      runtimeInputs = [ ];
      text = ''
        export SELF_CHECK_TOOLS=${lib.escapeShellArg (lib.concatStringsSep " " expectedTools)}
        export SELF_CHECK_RULES=${lib.escapeShellArg (builtins.toJSON sandboxAllowRules)}
        export SELF_CHECK_CONTAINER_MARKER=/run/.containerenv
        export SELF_CHECK_SETTINGS=/etc/claude-code/managed-settings.json
        export SELF_CHECK_NIX_SOCKET=/nix/var/nix/daemon-socket/socket
        export SELF_CHECK_JQ=${pkgs.jq}/bin/jq
        export SELF_CHECK_TIMEOUT=${pkgs.coreutils}/bin/timeout
        ${builtins.readFile ./claude-sandbox-self-check.sh}
      '';
    };

    # Basic Linux and developer tools for use inside the sandbox (the slim
    # Debian image has little beyond coreutils/grep/sed), plus whatever other
    # modules add through programs.claudeSandbox.extraPackages (e.g. the
    # tix tools, see modules/apps/tix.nix). They come
    # before the image's /usr/bin on PATH, so they shadow its own copies.
    # (baseDevTools is shared with kiro-sandbox, which adds its own extras.)
    baseDevTools = with pkgs; [
        git
        coreutils findutils diffutils gnugrep gnused gawk patch less file
        which tree ripgrep fd jq yq-go bc
        gnutar gzip bzip2 xz zstd zip unzip
        procps psmisc util-linux lsof strace
        curl wget iproute2 netcat-openbsd dnsutils rsync
        gnumake
        shellcheck
        # Jujutsu (jj), for rewriting a ticket branch's unpushed commits into a
        # tidy history in a scratch clone (the tix:tidy skill).
        jujutsu
        # ssh-keygen for the signing testscripts (client tools only, no sshd).
        openssh
        # The nix client, for `nix eval` / `nix flake check --no-build` through
        # the host nix-daemon (claude-sandbox.sh mounts its socket). pkgs.nix and
        # not config.nix.package: this is a home-manager module, where the
        # system option is out of reach without osConfig; the client only needs
        # to speak to the daemon, whose version is the host's.
        # Client newer than the daemon is fine; if `nix` ever errors on the
        # protocol after a flake update, pin the client to the host's version
        # (osConfig.nix.package when HM runs as a NixOS module).
        nix
    ];
    devToolsEnv = pkgs.buildEnv {
      name = "claude-sandbox-dev-tools";
      paths = baseDevTools ++ [ selfCheck ] ++ cfg.extraPackages;
    };

    # programs.claudeSandbox.extraMcpServers as an MCP config file in the
    # store (reached through the read-only /nix/store mount); the launcher
    # merges it with sandbox-proxy's servers
    extraMcpConfig = lib.optionalString (cfg.extraMcpServers != { })
      (toString (pkgs.writeText "claude-sandbox-extra-mcp.json"
        (builtins.toJSON { mcpServers = cfg.extraMcpServers; })));

    # Managed settings for the container only (mounted read-only at
    # /etc/claude-code/managed-settings.json): allow rules so Claude Code's
    # permission layer doesn't stop kill commands, file deletes or pushes
    # inside the sandbox, and denies for force pushes and deletes, which no
    # other settings file can lift. The host's settings are untouched.
    managedSettings = pkgs.writeText "claude-sandbox-managed-settings.json"
      (builtins.toJSON {
        permissions.allow = sandboxAllowRules;
        permissions.deny = sandboxDenyRules;
      });

    # The launcher's environment that doesn't depend on the agent (shared
    # with kiro-sandbox through programs.claudeSandbox.shared)
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
      export GIT_GLOBAL_IGNORE=${config.xdg.configFile."git/ignore".source}
      export GIT_GLOBAL_CONFIG=${config.xdg.configFile."git/config".source}
      export CACERT_BUNDLE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
      export HERDR_BIN=${lib.getExe pkgs.herdr}
    '';

    # One launcher, installed as claude and as claude-sandbox (whose --help
    # describes the sandbox). SANDBOX_CONFIG_RO_PATHS is colon-separated, so
    # no readOnlyPaths entry may contain a colon: the assert below fails the
    # evaluation with that message instead of splitting the entry in two at
    # launch.
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
        # the configured lists; SANDBOX_PASS_ENV / SANDBOX_RO_PATHS in the
        # environment add to them
        export SANDBOX_CONFIG_PASS_ENV=${lib.escapeShellArg (lib.concatStringsSep " " cfg.passEnv)}
        export SANDBOX_CONFIG_RO_PATHS=${lib.escapeShellArg (lib.concatStringsSep ":" cfg.readOnlyPaths)}
        export CLAUDE_CODE=${cfg.package}
        ${commonExports}
        export DEV_TOOLS_BIN=${devToolsEnv}/bin
        export MANAGED_SETTINGS=${managedSettings}
        export EXTRA_MCP_CONFIG=${lib.escapeShellArg extraMcpConfig}
        export CLAUDE_LSP_PLUGIN=${lspPlugin}
        # AGENT=<profile> (modules/apps/agents): AGENT_PROFILE / AGENT_HOME
        # for the launcher, which mounts that home as Claude's config dir
        ${config.programs.agents.profileLib}
        agent_profile claude
        # argv[0] "claude" (for both names) so herdr, which identifies agents
        # by the pane's foreground processes, recognises the session: the
        # real claude runs inside the container, out of its sight
        exec -a claude bash ${./claude-sandbox.sh} "$@"
      '';
    };
  in {
    # claude-code for the sandbox and claude-open, from the
    # flake's locked nixpkgs (allowUnfree is set in hosts/common.nix): it moves
    # with `nix flake update`, and a launch evaluates and downloads nothing.
    options.programs.claudeSandbox.package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.claude-code;
      defaultText = lib.literalExpression "pkgs.claude-code";
      description = "claude-code package run by claude (sandboxed), claude-sandbox and claude-open.";
    };

    # Container image, pinned to an exact tag and the digest of its
    # multi-arch index (UPDATES.md says how to bump)
    options.programs.claudeSandbox.image = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/library/debian:trixie-20260918-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a";
      readOnly = true;
      description = "Pinned image claude-sandbox runs Claude in.";
    };
    # Host variables passed into the sandbox (name globs), built into the
    # launcher so they apply right after a switch; SANDBOX_PASS_ENV in the
    # environment adds more
    options.programs.claudeSandbox.passEnv = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "TIX_*" ];
      description = "Names (globs) of host environment variables passed into the sandbox.";
    };

    # Host paths every session gets read-only at the same path (also when
    # the session didn't pass them as --add-dir), e.g. a cache a tool reads;
    # built into the launcher, SANDBOX_RO_PATHS (colon-separated) adds more
    options.programs.claudeSandbox.readOnlyPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "~/.cache/some-tool/models" ];
      description = "Host paths mounted read-only in every sandbox session; ~ and $HOME are expanded at launch, missing paths skipped.";
    };

    options.programs.claudeSandbox.extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Packages whose bin/ is put on PATH inside claude-sandbox (reached through the read-only /nix/store mount).";
    };

    # MCP servers every sandboxed session gets, next to sandbox-proxy's:
    # Claude Code mcpServers entries by server name.
    # Their commands run inside the sandbox, so they must be /nix/store paths
    # (or tools on its PATH).
    options.programs.claudeSandbox.extraMcpServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
      example = lib.literalExpression ''
        { foo = { command = lib.getExe pkgs.foo-mcp; args = [ "--stdio" ]; }; }
      '';
      description = "Extra stdio MCP servers (Claude Code mcpServers entries, by name) for every claude-sandbox session.";
    };

    # Language servers behind Claude's LSP tool (definitions, references,
    # call hierarchy, symbols), as .lsp.json entries by name. Each is
    # started on demand for the files it claims, inside the sandbox when
    # the session is sandboxed, so commands are /nix/store paths. gopls
    # takes `go` from the session's PATH (asdf), typescript-language-server
    # a project's own typescript when it has one, and ruby-lsp only indexes
    # the code (it runs on its own Ruby, so any project Ruby version works),
    # writing its bundle to .ruby-lsp/ (self-ignored) in the working
    # directory. dart is Dart's and Flutter's analysis server; in a Flutter
    # project it resolves package:flutter through .dart_tool/
    # package_config.json, so `flutter pub get` must have run. No SQL server: sqls answers nothing without a configured
    # database connection, and HAML/ERB have none worth running.
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
        python = {
          command = lib.getExe' pkgs.basedpyright "basedpyright-langserver";
          args = [ "--stdio" ];
          extensionToLanguage = { ".py" = "python"; ".pyi" = "python"; };
        };
      };
      description = "Language servers (Claude Code .lsp.json entries, by name) for the LSP tool in every claude and claude-open session.";
    };

    # What kiro-sandbox (modules/apps/kiro/kiro-sandbox.nix) shares with
    # this launcher: the script itself (SANDBOX_AGENT picks the agent), the
    # agent-independent part of its environment, its runtime inputs, the base
    # dev tools and the git update. Internal: not a setting.
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

    # The commands modules/apps/agents' agent / agent-open run for a claude
    # profile. Internal: not a setting.
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
