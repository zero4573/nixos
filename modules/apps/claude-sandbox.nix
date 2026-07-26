_: {
  # `claude-sandbox`: launches Claude Code inside a podman container scoped to
  # the current project directory, with asdf (installs/shims/plugins -- see
  # profiles/desktop.nix and profiles/work.nix for the plugin lists; asdf
  # itself is wired up in modules/apps/zsh.nix) mounted in wholesale so it
  # resolves .tool-versions natively inside the sandbox, exactly as it does
  # on the host. Claude Code is fetched ephemerally via `nix build` rather
  # than declared as a permanent package here.
  #
  # Only the project directory is mounted read-write. All of ~/.asdf is
  # mounted read-only -- the safety property that matters is read-only, not
  # scope, since it's what stops a compromised/misled run from planting a
  # backdoored toolchain binary that would then run on the host outside the
  # sandbox. Claude's own auth state (~/.claude, ~/.claude.json) is the one
  # read-write exception, since without it every run would need a fresh
  # login. This contains filesystem blast radius, not network egress: Claude
  # needs outbound HTTPS for the Anthropic API, so podman's default rootless
  # networking (modules/apps/containers.nix) is left untouched.
  flake.homeModules.claudeSandbox = { pkgs, lib, ... }:
  let
    claudeSandbox = pkgs.writeShellApplication {
      name = "claude-sandbox";
      runtimeInputs = [ pkgs.podman pkgs.nix ];
      text = ''
        # Walk up from $PWD looking for the nearest .tool-versions, mirroring
        # asdf's own upward search, so the mounted project root matches what
        # asdf would use to resolve versions.
        project_root="$PWD"
        tool_versions=""
        dir="$PWD"
        while true; do
          if [[ -f "$dir/.tool-versions" ]]; then
            project_root="$dir"
            tool_versions="$dir/.tool-versions"
            break
          fi
          [[ "$dir" == "/" ]] && break
          dir="$(dirname "$dir")"
        done

        if [[ -z "$tool_versions" ]]; then
          echo "claude-sandbox: no .tool-versions found above $PWD; sandbox will have no language toolchains" >&2
        fi

        asdf_data_dir="$HOME/.asdf"

        # Fetch Claude Code ephemerally -- never declared as a permanent
        # package, so nothing here persists outside the Nix store's own
        # cache.
        claude_out="$(nix build --no-link --print-out-paths 'nixpkgs#claude-code')"

        # Claude's own auth/session state is the one exception to
        # "project dir only": it's the tool's state, not the rest of the
        # system, and without it every sandboxed run would need a fresh
        # login.
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

    # Short convenience alias; home.file.".alias".text is `types.lines`, so
    # this concatenates with the aliases set in modules/apps/zsh.nix rather
    # than conflicting with them.
    home.file.".alias".text = ''
      alias claude='NIXPKGS_ALLOW_UNFREE=1 nix-shell -p claude-code --run "claude"'
      alias ccs='claude-sandbox'
    '';
  };
}
