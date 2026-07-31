_: {
  # Creates a shell application to launch claude in a sandboxed environment
  # with basic developer tools.
  #
  # Does the following:
  #  * claude alias - sets up an alias so the `claude` command sets up a basic
  #       claud in a nix shell, does not provide sandboxing, useful for
  #       running claude to help with tasks that require access to the main os
  #  * claude-sandbox - the scrip that runs claude in a sandbox, launches
  #       in the current directory. Runs the outer container `--privileged`
  #       so claude can create its own nested rootless podman containers for
  #       throwaway builds/tests. This is safe because the outer container
  #       itself is still a rootless podman container: `--privileged` only
  #       grants full capabilities within that already-namespaced boundary,
  #       and real host devices stay unreadable (checked against the real
  #       unprivileged host uid, not the container's mapped "root") -- it
  #       does not grant host root or touch the host's own podman/docker
  #       socket. Nested container storage lives in the outer container's
  #       own ephemeral rootfs, so it never persists past `--rm`.
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

    # Runs once at container start, before handing off to claude, to wire up
    # a self-contained podman storage/config for the nested podman.
    nestedPodmanSetup = pkgs.writeShellScript "claude-sandbox-nested-podman-setup" ''
      set -e
      mkdir -p /etc/containers /var/lib/containers/storage /run/containers/storage
      echo "root:1:65535" > /etc/subuid
      echo "root:1:65535" > /etc/subgid

      cat > /etc/containers/storage.conf <<EOF
      [storage]
      driver = "overlay"
      runroot = "/run/containers/storage"
      graphroot = "/var/lib/containers/storage"
      EOF

      cat > /etc/containers/registries.conf <<EOF
      unqualified-search-registries = ["docker.io"]
      EOF

      cat > /etc/containers/policy.json <<'INNEREOF'
      { "default": [{ "type": "insecureAcceptAnything" }] }
      INNEREOF

      cat > /etc/containers/containers.conf <<EOF
      [engine]
      conmon_path = ["${nestedPodmanEnv}/bin/conmon"]
      runtime = "crun"
      [engine.runtimes]
      crun = ["${nestedPodmanEnv}/bin/crun"]
      [network]
      network_backend = "netavark"
      EOF

      export XDG_RUNTIME_DIR=/run/user/0
      mkdir -p "$XDG_RUNTIME_DIR"

      exec "$@"
    '';

    claudeSandbox = pkgs.writeShellApplication {
      name = "claude-sandbox";
      runtimeInputs = [ pkgs.podman pkgs.nix ];
      text = ''
        project_root="$PWD"
        asdf_data_dir="$HOME/.asdf"

        export NIXPKGS_ALLOW_UNFREE=1
        claude_out="$(NIXPKGS_ALLOW_UNFREE=1 nix build \
            --impure \
            --no-link \
            --print-out-paths \
            'nixpkgs#claude-code'
        )"

        # Claude's own auth/session state
        mkdir -p "$HOME/.claude"
        touch "$HOME/.claude.json"

        exec podman run --rm -it \
          --privileged \
          --pull=missing \
          -v /nix/store:/nix/store:ro \
          -v "$project_root:$project_root:rw" \
          -w "$PWD" \
          -v "$asdf_data_dir:$asdf_data_dir:ro" \
          -v "$HOME/.claude:$HOME/.claude:rw" \
          -v "$HOME/.claude.json:$HOME/.claude.json:rw" \
          -e HOME="$HOME" \
          -e ASDF_DATA_DIR="$asdf_data_dir" \
          -e SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" \
          -e PATH="$asdf_data_dir/shims:${pkgs.asdf-vm}/bin:${nestedPodmanEnv}/bin:$claude_out/bin:/usr/bin:/bin" \
          docker.io/library/debian:stable-slim \
          ${nestedPodmanSetup} "$claude_out/bin/claude" "$@"
      '';
    };
  in {
    home.packages = [ claudeSandbox ];

    home.file.".alias".text = ''
      alias claude='NIXPKGS_ALLOW_UNFREE=1 nix-shell -p claude-code --run "claude"'
    '';
  };
}
