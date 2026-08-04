_: {
  flake.homeModules.claudeCode = { pkgs, lib, ... }:
  let
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
    };
    settingsFile = pkgs.writeText "claude-code-settings.json" (builtins.toJSON settings);
  in {
    home.activation.claudeCodeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p "$HOME/.claude"
      run install -m 0644 ${settingsFile} "$HOME/.claude/settings.json"
    '';
  };
}
