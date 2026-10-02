_: {
  # Creates a shell application to launch claude in a sandboxed environment
  # with basic developer tools.
  #
  # Does the following:
  #  * claude - runs a basic claude in a nix shell, does not provide
  #       sandboxing, useful for running claude to help with tasks that
  #       require access to the main os
  #
  #  Both claude and claude-sandbox first bring a git checkout in the current
  #  directory up to date (claude-git-update.sh): fetch, then fast-forward
  #  the current branch to its upstream. Diverged branches or local changes
  #  in the way are reported and left alone; the launch always proceeds.
  #
  #  * claude-sandbox - the script that runs claude in a sandbox, launches
  #       in the current directory. Claude is launched with asdf tools, and
  #       the ability to spawn its own containers, sandboxed to the running
  #       claude-sandbox container.  You can provide the additional run
  #       arguemnt `--ports 3000,5173` to mount the claude containers ports
  #       so you can locally connect to applications the sandboxed claude
  #       brings up if needed. `--dirs /path/one,/path/two` bind-mounts
  #       additional host directories into the container read-write (at the
  #       same absolute path) and registers them with claude via --add-dir,
  #       for tasks that need context from more than one project. `--` stops
  #       claude-sandbox's own flag parsing so everything after it is passed
  #       straight through to the claude CLI untouched. This will automatically
  #       join the sandbox-proxy credential broker networks (see
  #       modules/apps/sandbox-proxy/sandbox-proxy.nix): `sandbox-registry`
  #       whenever `sandbox-proxy host-login` has been configured, and
  #       `sandbox-mcp` whenever MCP servers were added with
  #       `sandbox-proxy mcp add` (e.g. Jira/Bitbucket via Atlassian Rovo),
  #       which are then registered with claude without their tokens.
  #       The pod and its containers are named after the git repo + checkout
  #       folder (claude-sandbox-<repo>-<folder>[-N], with -claude/-graphify
  #       container suffixes) and labelled claude-sandbox.{repo,project,role},
  #       e.g. `podman ps --filter label=claude-sandbox.repo=<repo>`.
  #       Claude runs in a podman pod next to a graphify sidecar
  #       (claude-sandbox-graphify-sidecar.sh) that builds a code knowledge
  #       graph of the project (local tree-sitter AST, no LLM), keeps it
  #       updated, and serves it to Claude as the `graphify` MCP server on the
  #       pod's localhost; the graph lives in ./graphify-out (globally
  #       git-ignored, see modules/apps/git.nix). `--no-graphify` skips
  #       the sidecar for one session. The
  #       container itself runs under the `ai-sandbox.slice` systemd user
  #       slice (see modules/apps/ai-sandbox-slice.nix) so it fair-shares
  #       CPU/IO/memory against the rest of the desktop session under load.
  #
  # Script bodies live in sibling .sh files (claude-sandbox.sh,
  # claude-sandbox-nested-podman-setup.sh, claude-sandbox-graphify-sidecar.sh)
  flake.homeModules.claudeSandbox = { pkgs, lib, config, ... }:
  let
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

    # Pinned graphifyy release the graphify sidecar pip-installs into the
    # shared `claude-sandbox-graphify` podman volume (graphifyy isn't in
    # nixpkgs). Bumping this reinstalls on the next sandbox start.
    graphifyVersion = "0.9.73";

    gitUpdate = pkgs.writeShellScript "claude-git-update" ''
      export PATH=${lib.makeBinPath [ pkgs.git pkgs.coreutils ]}:$PATH
      ${builtins.readFile ./claude-git-update.sh}
    '';

    claude = pkgs.writeShellApplication {
      name = "claude";
      text = ''
        ${gitUpdate} "$PWD"
        exec env NIXPKGS_ALLOW_UNFREE=1 nix-shell -p claude-code --run "claude $(printf '%q ' "$@")"
      '';
    };

    nestedPodmanSetup = pkgs.writeShellScript "claude-sandbox-nested-podman-setup"
      (builtins.readFile ./claude-sandbox-nested-podman-setup.sh);

    # Basic developer tools for use inside the sandbox
    devToolsEnv = pkgs.buildEnv {
      name = "claude-sandbox-dev-tools";
      paths = [ pkgs.git ];
    };

    claudeSandbox = pkgs.writeShellApplication {
      name = "claude-sandbox";
      runtimeInputs = [ pkgs.podman pkgs.nix pkgs.systemd pkgs.xdg-dbus-proxy pkgs.coreutils pkgs.jq pkgs.git pkgs.gnused ];
      text = ''
        export NESTED_PODMAN_SETUP=${nestedPodmanSetup}
        export NESTED_PODMAN_ENV_BIN=${nestedPodmanEnv}/bin
        export DEV_TOOLS_BIN=${devToolsEnv}/bin
        export ASDF_VM_BIN=${pkgs.asdf-vm}/bin
        export GRAPHIFY_SIDECAR=${./claude-sandbox-graphify-sidecar.sh}
        export GRAPHIFY_VERSION=${graphifyVersion}
        export CLAUDE_GIT_UPDATE=${gitUpdate}
        export GIT_GLOBAL_IGNORE=${config.xdg.configFile."git/ignore".source}
        export CACERT_BUNDLE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        exec bash ${./claude-sandbox.sh} "$@"
      '';
    };
  in {
    home.packages = [ claudeSandbox claude ];
  };
}
