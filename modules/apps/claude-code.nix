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
      systemPrompt = "if AGENTS.md exists, read it as CLAUDE.md.  Ensure that both AGENTS.md, and README.md (if it exists), are always kept up to date when a prompt changes a project";
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

    # Locally-authored skills: one subdirectory per skill under ./skills,
    # each holding a SKILL.md (see modules/apps/skills/README.md). Copied
    # wholesale into ~/.claude/skills/.
    skillsSource = ./skills;

    # Skills pulled from external git repos, e.g.:
    #   {
    #     url = "https://github.com/someuser/some-skills-repo.git";
    #     ref = "main";        # branch/tag hint, used to speed up the fetch
    #     rev = "3f1a2b...c9"; # exact commit - this is what actually pins it.
    #                          # Find/bump it with: git ls-remote <url> <ref>
    #     path = "skills";     # subdirectory in the repo containing skill
    #                          # folders; "" = repo root
    #     only = null;         # null = take every skill dir found under
    #                          # `path`; or e.g. [ "foo" "bar" ] for a subset
    #   }
    # `rev` is required (not just `ref`) so this fetch stays pure - this
    # repo's rebuilds never pass --impure, and Nix's pure evaluation mode
    # requires an exact commit to fetch reproducibly. Bump `rev` by hand to
    # pull in newer content from a source.
    skillSources = [ ];

    # For each configured source: fetch it, then either copy everything
    # under `path` (only == null) or just the named subdirectories.
    skillCopyCommands = lib.concatMapStrings (
      s:
      let
        src = builtins.fetchGit { inherit (s) url ref rev; };
        root = if s.path == "" then src else "${src}/${s.path}";
      in
      if s.only == null then
        ''
          run cp -r ${root}/. "$HOME/.claude/skills/"
        ''
      else
        lib.concatMapStrings (name: ''
          run cp -r ${root}/${name} "$HOME/.claude/skills/${name}"
        '') s.only
    ) skillSources;
  in {
    home.packages = [ pkgs.libnotify ];

    home.activation.claudeCodeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p "$HOME/.claude"
      run install -m 0644 ${settingsFile} "$HOME/.claude/settings.json"
    '';

    # ~/.claude/skills is fully Nix-owned: wiped and repopulated from
    # skillsSource + skillSources on every switch
    home.activation.claudeCodeSkills = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run rm -rf "$HOME/.claude/skills"
      run mkdir -p "$HOME/.claude/skills"
      run cp -r ${skillsSource}/. "$HOME/.claude/skills/"
      ${skillCopyCommands}
      run chmod -R u+rwX "$HOME/.claude/skills"
    '';
  };
}
