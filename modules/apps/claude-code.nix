_: {
  flake.homeModules.claudeCode = { pkgs, lib, ... }:
  let
    # Desktop-notifies via notify-send. Reads the hook's JSON payload
    # from stdin for an optional `.message` and `.cwd` (falls back to $1 /
    # a generic title when absent, e.g. for the Stop event). Baked as an
    # absolute /nix/store path, so this also works unmodified inside
    # claude-sandbox, which bind-mounts /nix/store read-only and shares this
    # same settings.json with the host.
    notifyScript = pkgs.writeShellScript "claude-code-notify" ''
      set -euo pipefail
      default_message="''${1:-Claude Code}"
      input="$(cat)"
      cwd="$(${lib.getExe pkgs.jq} -r '.cwd // empty' <<<"$input" 2>/dev/null || true)"
      message="$(${lib.getExe pkgs.jq} -r --arg d "$default_message" '.message // $d' <<<"$input" 2>/dev/null || echo "$default_message")"
      title="Claude Code"
      [[ -n "$cwd" ]] && title="Claude Code ($(basename "$cwd"))"
      ${lib.getExe' pkgs.libnotify "notify-send"} -a "Claude Code" "$title" "$message" || true
    '';

    settings = {
      theme = "dark";
      tui = "fullscreen";
      verbose = true;
      useAutoModeDuringPlan = true;
      notifications = true;
      autoUpdate = false;
      systemPrompt = "if AGENTS.md exists, read it as CLAUDE.md";
      bash = {
        deniedCommands = [
          "rm -rf"
          "git push"
          "DROP TABLE"
          "truncate"
          "nixos-install"
        ];
        allowedCommands = [
          "npm test"
          "npm run lint"
          "git status"
          "git diff"
          "ls"
          "cat"
          "echo"
        ];
      };
      hooks = {
        Notification = [
          { matcher = ""; hooks = [ { type = "command"; command = "${notifyScript}"; } ]; }
        ];
        Stop = [
          { matcher = ""; hooks = [ { type = "command"; command = ''${notifyScript} "Finished responding"''; } ]; }
        ];
      };
    };
    settingsFile = pkgs.writeText "claude-code-settings.json" (builtins.toJSON settings);
  in {
    home.packages = [ pkgs.libnotify ];

    home.activation.claudeCodeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p "$HOME/.claude"
      run install -m 0644 ${settingsFile} "$HOME/.claude/settings.json"
    '';
  };
}
