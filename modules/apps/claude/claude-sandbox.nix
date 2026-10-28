{ inputs, ... }: {
  # Claude Code, sandboxed by default:
  #
  #  * claude - Claude Code in a sandbox (claude-sandbox.sh): a privileged
  #       rootless podman container scoped to the current directory, with asdf
  #       tools and its own nested podman. Every argument is claude's own and
  #       passes through untouched; what the session may touch follows
  #       Claude's settings (--add-dir and permissions.additionalDirectories
  #       mount read-write, Edit/Write deny rules inside them read-only).
  #       Sandbox-only settings are environment variables (CLAUDE_SANDBOX_*:
  #       ports, pod name, quiet launch, no graphify, host variables to pass
  #       in, read-only host paths: programs.claudeSandbox.readOnlyPaths);
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
  #  (claude-sandbox-<repo>-<folder>[-N], with -claude/-graphify container
  #  suffixes) and labelled claude-sandbox.{repo,project,role}, e.g.
  #  `podman ps --filter label=claude-sandbox.repo=<repo>`. Next to Claude runs
  #  a graphify sidecar (claude-sandbox-graphify-sidecar.sh) that builds a code
  #  knowledge graph of the project (local tree-sitter AST, no LLM), keeps it
  #  updated, and serves it as the `graphify` MCP server on the pod's
  #  localhost; the graph lives in ./graphify-out (globally git-ignored, see
  #  modules/apps/git.nix). Each --add-dir codebase (one with parseable code,
  #  not overlapping the project) is graphed into its own graphify-out too,
  #  and the sidecar then serves all of them merged into one graph (node ids
  #  prefixed per directory, re-merged as they change; they build in the
  #  background, so a large one never delays startup). A session that
  #  brings its own graphify server (--mcp-config) skips it. Either way, a
  #  session with a graphify server gets GRAPHIFY_MCP=1, which
  #  claude-code.nix's SessionStart hook turns into an instruction to use the
  #  graph tools first. Every session also gets the stdio MCP servers in
  #  programs.claudeSandbox.extraMcpServers: by default `fff` (fff-mcp, fast
  #  file and content search, from the fff flake input). The sandbox's PATH
  #  gets programs.claudeSandbox.extraPackages. The containers run under the
  #  `aisandbox.slice` systemd user slice (see modules/apps/ai-sandbox-slice.nix)
  #  so they fair-share CPU/IO/memory with the rest of the desktop session.
  #  Each launch step is timestamped on stderr and logged to
  #  ~/.local/state/claude-sandbox.log, to see where a slow or stuck launch is.
  #
  #  Everything a session runs is pinned: claude-code comes from the flake's
  #  nixpkgs, the container images by digest, and graphify by a hashed pip
  #  lock (claude-sandbox-graphify-lock writes it). See UPDATES.md.
  #
  # Script bodies live in sibling files (claude-sandbox.sh,
  # claude-sandbox-nested-podman-setup.sh, claude-sandbox-graphify-sidecar.sh,
  # claude-sandbox-graphify-install.sh, claude-sandbox-graphify-lock.sh)
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

    inherit (cfg) graphifyVersion graphifyInstallScript graphifyLock graphifyImage;
    graphifyExtras = lib.concatStringsSep "," cfg.graphifyExtras;
    graphifySpec = "graphifyy[${graphifyExtras}]==${graphifyVersion}";
    # Python minor version of graphifyImage, which the lock is resolved for
    graphifyPython = "3.12";

    # Bumps the graphify lock (see claude-sandbox-graphify-lock.sh, UPDATES.md)
    graphifyLockTool = pkgs.writeShellApplication {
      name = "claude-sandbox-graphify-lock";
      runtimeInputs = [ pkgs.uv pkgs.coreutils pkgs.gnused ];
      text = ''
        export GRAPHIFY_VERSION=${graphifyVersion}
        export GRAPHIFY_EXTRAS=${graphifyExtras}
        export GRAPHIFY_PYTHON=${graphifyPython}
        ${builtins.readFile ./claude-sandbox-graphify-lock.sh}
      '';
    };

    gitUpdate = pkgs.writeShellScript "claude-git-update" ''
      export PATH=${lib.makeBinPath [ pkgs.git pkgs.coreutils ]}:$PATH
      ${builtins.readFile ./claude-git-update.sh}
    '';

    claudeOpen = pkgs.writeShellApplication {
      name = "claude-open";
      text = ''
        ${gitUpdate} "$PWD"
        exec ${lib.getExe' cfg.package "claude"} "$@"
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
    # claude-tickets tools, see modules/apps/claude-tickets.nix). They come
    # before the image's /usr/bin on PATH, so they shadow its own copies.
    devToolsEnv = pkgs.buildEnv {
      name = "claude-sandbox-dev-tools";
      paths = with pkgs; [
        git
        coreutils findutils diffutils gnugrep gnused gawk patch less file
        which tree ripgrep fd jq yq-go bc
        gnutar gzip bzip2 xz zstd zip unzip
        procps psmisc util-linux lsof strace
        curl wget iproute2 netcat-openbsd dnsutils rsync
        gnumake
        shellcheck
        # Jujutsu (jj), for rewriting a ticket branch's unpushed commits into a
        # tidy history in a scratch clone (the tickets:tidy skill).
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
        selfCheck
      ] ++ cfg.extraPackages;
    };

    # programs.claudeSandbox.extraMcpServers as an MCP config file in the
    # store (reached through the read-only /nix/store mount); the launcher
    # merges it with sandbox-proxy's and graphify's servers
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

    # One launcher, installed as claude and as claude-sandbox (whose --help
    # describes the sandbox). CLAUDE_SANDBOX_RO_PATHS is colon-separated, so
    # no readOnlyPaths entry may contain a colon: the assert below fails the
    # evaluation with that message instead of splitting the entry in two at
    # launch.
    sandboxLauncher = name:
      assert lib.assertMsg
        (lib.all (p: !(lib.hasInfix ":" p)) cfg.readOnlyPaths)
        "programs.claudeSandbox.readOnlyPaths: no entry may contain ':'";
      pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.podman pkgs.systemd pkgs.xdg-dbus-proxy pkgs.coreutils pkgs.jq pkgs.git pkgs.gnused ];
      text = ''
        export CLAUDE_SANDBOX_AS=${name}
        export CLAUDE_SANDBOX_PASS_ENV="''${CLAUDE_SANDBOX_PASS_ENV:-${lib.concatStringsSep " " cfg.passEnv}}"
        export CLAUDE_SANDBOX_RO_PATHS="''${CLAUDE_SANDBOX_RO_PATHS:-${lib.concatStringsSep ":" cfg.readOnlyPaths}}"
        export CLAUDE_CODE=${cfg.package}
        export CLAUDE_SANDBOX_IMAGE=${lib.escapeShellArg cfg.image}
        export NESTED_PODMAN_SETUP=${nestedPodmanSetup}
        export NESTED_PODMAN_ENV_BIN=${nestedPodmanEnv}/bin
        export DEV_TOOLS_BIN=${devToolsEnv}/bin
        export MANAGED_SETTINGS=${managedSettings}
        export NIX_DAEMON_SOCKET_DIR=/nix/var/nix/daemon-socket
        export ASDF_VM_BIN=${pkgs.asdf-vm}/bin
        export GRAPHIFY_SIDECAR=${./claude-sandbox-graphify-sidecar.sh}
        export GRAPHIFY_IMAGE=${lib.escapeShellArg graphifyImage}
        export GRAPHIFY_LOCK=${graphifyLock}
        export GRAPHIFY_INSTALL=${graphifyInstallScript}
        export EXTRA_MCP_CONFIG=${lib.escapeShellArg extraMcpConfig}
        export CLAUDE_GIT_UPDATE=${gitUpdate}
        export GIT_SSH_BROKER=${lib.getExe' config.programs.gitSshBroker.package "git-ssh-broker"}
        export GIT_SSH_BROKER_SSH=${lib.getExe' pkgs.openssh "ssh"}
        export GIT_SSH_BROKER_UPSTREAM_AGENT=${lib.escapeShellArg config.programs.gitSshBroker.upstreamAgent}
        export CLAUDE_SANDBOX_SIGNING_KEYS=${lib.escapeShellArg (lib.concatStringsSep ":" config.programs.gitSshBroker.signingKeys)}
        export GIT_GLOBAL_IGNORE=${config.xdg.configFile."git/ignore".source}
        export GIT_GLOBAL_CONFIG=${config.xdg.configFile."git/config".source}
        export CACERT_BUNDLE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        exec bash ${./claude-sandbox.sh} "$@"
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

    # Container images, pinned to an exact tag and the digest of its
    # multi-arch index (UPDATES.md says how to bump). image runs Claude;
    # graphifyImage runs the graphify sidecar, and its Python minor version
    # must match the lock's (graphifyPython above).
    options.programs.claudeSandbox.image = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/library/debian:trixie-20260918-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a";
      readOnly = true;
      description = "Pinned image claude-sandbox runs Claude in.";
    };
    options.programs.claudeSandbox.graphifyImage = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/library/python:3.12.15-slim-trixie@sha256:29113dcae7aad06daa8e95260fa09f27d62be33b9687ea3774f771d601a02256";
      readOnly = true;
      description = "Pinned Python image for the graphify sidecar.";
    };

    # Hashed pip lock of graphifyy, its extras and every dependency
    # (claude-sandbox-graphify-requirements.txt, written by
    # claude-sandbox-graphify-lock). The sidecar installs
    # exactly this, with pip --require-hashes; a new lock installs into a new
    # venv on the next start.
    options.programs.claudeSandbox.graphifyLock = lib.mkOption {
      type = lib.types.path;
      default = ./claude-sandbox-graphify-requirements.txt;
      readOnly = true;
      description = "Hashed pip requirements the graphify sidecar installs.";
    };

    # Pinned graphifyy release (graphifyy isn't in nixpkgs). With
    # graphifyExtras, it's what the lock was resolved from: the build fails
    # until the lock matches (regenerate it with claude-sandbox-graphify-lock).
    options.programs.claudeSandbox.graphifyVersion = lib.mkOption {
      type = lib.types.str;
      default = "0.9.73";
      readOnly = true;
      description = "graphifyy release used by claude-sandbox's graphify sidecar.";
    };

    # pip extras installed with graphifyy. Besides the MCP server and watch
    # mode, these are the tree-sitter grammars graphify doesn't bundle; without
    # one, files of that language add nothing to the graph (graphify warns
    # "<lang> not installed"). Left out on purpose: r and erlang (they pull
    # the large tree-sitter-language-pack), robot, and the non-code extras
    # (LLM backends, pdf, video, office, neo4j, ...). Changing the list means
    # regenerating the lock (see graphifyVersion).
    options.programs.claudeSandbox.graphifyExtras = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "mcp" "watch" "sql" "terraform" "pascal" "dm" "ocaml" "commonlisp" "vbnet" "solidity" ];
      readOnly = true;
      description = "pip extras of graphifyy installed for claude-sandbox's graphify sidecar.";
    };

    # The shared install step (claude-sandbox-graphify-install.sh), used by the
    # sidecar
    options.programs.claudeSandbox.graphifyInstallScript = lib.mkOption {
      type = lib.types.path;
      default = ./claude-sandbox-graphify-install.sh;
      readOnly = true;
      description = "Script that installs graphify into the shared claude-sandbox-graphify volume.";
    };

    # Host variables passed into the sandbox (name globs), built into the
    # launcher so they apply right after a switch; CLAUDE_SANDBOX_PASS_ENV
    # in the environment wins
    options.programs.claudeSandbox.passEnv = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "CLAUDE_TICKETS_*" ];
      description = "Names (globs) of host environment variables passed into the sandbox.";
    };

    # Host paths every session gets read-only at the same path (also when
    # the session didn't pass them as --add-dir), e.g. a cache a tool reads;
    # built into the launcher, CLAUDE_SANDBOX_RO_PATHS (colon-separated) wins
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

    # MCP servers every sandboxed session gets, next to sandbox-proxy's and
    # the graphify sidecar's: Claude Code mcpServers entries by server name.
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

    # fff-mcp (tools find_files, grep, multi_grep), indexing the session's
    # working directory. Pinned by the fff flake input (flake.lock), so its
    # own update check is off.
    config.programs.claudeSandbox.extraMcpServers.fff = {
      command = lib.getExe' inputs.fff.packages.${pkgs.stdenv.hostPlatform.system}.fff-mcp "fff-mcp";
      args = [ "--no-update-check" ];
    };

    config.home.packages = [ (sandboxLauncher "claude") (sandboxLauncher "claude-sandbox") claudeOpen graphifyLockTool ];

    config.assertions = [
      {
        assertion = lib.hasInfix "# spec: ${graphifySpec}\n# python: ${graphifyPython} " (builtins.readFile graphifyLock);
        message = "claude-sandbox: ${toString graphifyLock} wasn't generated for ${graphifySpec} on Python ${graphifyPython}; regenerate it with claude-sandbox-graphify-lock (see UPDATES.md).";
      }
      {
        assertion = lib.hasInfix ":${graphifyPython}." graphifyImage;
        message = "claude-sandbox: graphifyImage (${graphifyImage}) isn't Python ${graphifyPython}, which the graphify lock is resolved for.";
      }
    ];
  };
}
