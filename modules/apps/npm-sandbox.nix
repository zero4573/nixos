_: {
  flake.homeModules.npmSandbox = { pkgs, lib, ... }:
  let
    npmSandbox = pkgs.writeShellApplication {
      name = "npm-sandbox";
      runtimeInputs = [ pkgs.podman pkgs.asdf-vm pkgs.gawk ];
      text = ''
        project_root="$PWD"

        if ! current_line="$(asdf current nodejs --no-header 2>&1)"; then
          echo "npm-sandbox: could not resolve a nodejs version via asdf for $project_root" >&2
          echo "$current_line" >&2
          exit 1
        fi
        node_version="$(awk '{print $2}' <<< "$current_line")"

        mounts=(-v "$project_root:$project_root:rw")
        if [ -f "$HOME/.npmrc" ]; then
          mounts+=(-v "$HOME/.npmrc:$HOME/.npmrc:ro")
        fi
        if [ -f "$project_root/.npmrc" ]; then
          mounts+=(-v "$project_root/.npmrc:$project_root/.npmrc:ro")
        fi

        exec podman run --rm \
          --pull=missing \
          "''${mounts[@]}" \
          -w "$project_root" \
          -e HOME="$HOME" \
          "docker.io/library/node:$node_version" \
          npm "$@"
      '';
    };
  in {
    home.packages = [ npmSandbox ];
  };
}
