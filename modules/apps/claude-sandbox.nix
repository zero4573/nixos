_: {
  # Creates a shell application to launch claude in a sandboxed environment
  # with basic developer tools.
  #
  # Does the following:
  #  * claude alias - sets up an alias so the `claude` command sets up a basic
  #       claud in a nix shell, does not provide sandboxing, useful for
  #       running claude to help with tasks that require access to the main os
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
  #       join the registry-proxy broker network (see modules/apps/registry-proxy.nix)
  #       whenever `registry-proxy host-login` has been configured. The
  #       container itself runs under the `ai-sandbox.slice` systemd user
  #       slice (see modules/apps/ai-sandbox-slice.nix) so it fair-shares
  #       CPU/IO/memory against the rest of the desktop session under load.
  #
  # Script bodies live in sibling .sh files (claude-sandbox.sh,
  # claude-sandbox-nested-podman-setup.sh)
  flake.homeModules.claudeSandbox = { pkgs, lib, ... }:
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

    nestedPodmanSetup = pkgs.writeShellScript "claude-sandbox-nested-podman-setup"
      (builtins.readFile ./claude-sandbox-nested-podman-setup.sh);

    claudeSandbox = pkgs.writeShellApplication {
      name = "claude-sandbox";
      runtimeInputs = [ pkgs.podman pkgs.nix pkgs.systemd pkgs.xdg-dbus-proxy ];
      text = ''
        export NESTED_PODMAN_SETUP=${nestedPodmanSetup}
        export NESTED_PODMAN_ENV_BIN=${nestedPodmanEnv}/bin
        export ASDF_VM_BIN=${pkgs.asdf-vm}/bin
        export CACERT_BUNDLE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        exec bash ${./claude-sandbox.sh} "$@"
      '';
    };
  in {
    home.packages = [ claudeSandbox ];

    home.file.".alias".text = ''
      alias claude='NIXPKGS_ALLOW_UNFREE=1 nix-shell -p claude-code --run "claude"'
    '';
  };
}
