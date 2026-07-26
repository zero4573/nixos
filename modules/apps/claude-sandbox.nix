_: {
  # Creates a shell application to launch claude in a sandboxed environment
  # with basic developer tools.
  #
  # Does the following:
  #  * claude alias - sets up an alias so the `claude` command sets up a basic
  #       claud in a nix shell, does not provide sandboxing, useful for
  #       running claude to help with tasks that require access to the main os
  #  * claude-sandbox - the scrip that runs claude in a sandbox, launches
  #       in the current directory
  flake.homeModules.claudeSandbox = { pkgs, lib, ... }:
  let
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
          --pull=missing \
          -v /nix/store:/nix/store:ro \
          -v "$project_root:$project_root:rw" \
          -w "$PWD" \
          -v "$asdf_data_dir:$asdf_data_dir:ro" \
          -v "$HOME/.claude:$HOME/.claude:rw" \
          -v "$HOME/.claude.json:$HOME/.claude.json:rw" \
          -e HOME="$HOME" \
          -e ASDF_DATA_DIR="$asdf_data_dir" \
          -e PATH="$asdf_data_dir/shims:${pkgs.asdf-vm}/bin:$claude_out/bin:/usr/bin:/bin" \
          docker.io/library/debian:stable-slim \
          "$claude_out/bin/claude" "$@"
      '';
    };
  in {
    home.packages = [ claudeSandbox ];

    home.file.".alias".text = ''
      alias claude='NIXPKGS_ALLOW_UNFREE=1 nix-shell -p claude-code --run "claude"'
    '';
  };
}
