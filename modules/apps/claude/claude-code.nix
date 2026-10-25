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
      # The session's folder (a ticket workspace is named after its ticket)
      if [[ -n "$cwd" ]]; then
        title="Claude Code ($(basename "$cwd"))"
      fi
      ${lib.getExe' pkgs.libnotify "notify-send"} -a "Claude Code" "$title" "$message" || true
    '';

    # SessionStart: when the session has a `graphify` MCP server (code graph
    # of the project), tells Claude to reach for it first. "Hooked up" means
    # GRAPHIFY_MCP=1 (claude-sandbox sets it when its sidecar or a caller's
    # --mcp-config provides the server) or a project .mcp.json defining one.
    # Its stdout becomes session context; runs again after /clear and compaction.
    graphifyContextScript = pkgs.writeShellScript "claude-code-graphify-context" ''
      set -uo pipefail
      cwd="$(${lib.getExe pkgs.jq} -r '.cwd // empty' 2>/dev/null || true)"
      cwd="''${cwd:-$PWD}"
      if [[ "''${GRAPHIFY_MCP:-}" != 1 ]] \
          && ! ${lib.getExe pkgs.jq} -e '.mcpServers.graphify' "$cwd/.mcp.json" >/dev/null 2>&1; then
        exit 0
      fi
      cat <<'EOF'
      This project has a code knowledge graph served by the `graphify` MCP server
      (mcp__graphify__* tools; kept current as files change). Use it first for questions
      about the codebase's structure, architecture, where something is defined or used,
      what depends on what, and how components connect, before broad Grep/Glob/Read
      sweeps: query_graph for a question, get_node / get_neighbors for a symbol or file,
      shortest_path for how A reaches B, god_nodes / graph_stats / get_community for an
      overview. Then read the files it points to for detail; fall back to search when the
      graph has no answer. Prefer these tools over the /graphify skill's CLI query flows
      for an existing graph, and don't rebuild graphify-out/ yourself.
      EOF
    '';

    settings = {
      theme = "dark";
      tui = "fullscreen";
      verbose = true;
      useAutoModeDuringPlan = true;
      notifications = true;
      autoUpdate = false;
      # Transcripts are what `claude --continue` resumes (e.g. a ticket
      # session restarted by `ct start`); keep them longer than the 30-day
      # default
      cleanupPeriodDays = 90;
      systemPrompt = "if AGENTS.md exists, read it as CLAUDE.md.  Ensure that both AGENTS.md, and README.md (if it exists), are always kept up to date when a prompt changes a project";
      # Ticket and kb sessions add stricter rules (no worktree removal, ...)
      # in their own .claude/settings.json (modules/apps/claude-tickets.nix).
      permissions = {
        deny = [
          "Bash(rm -rf:*)"
          "Bash(git push:*)"
          "Bash(*DROP TABLE*)"
          "Bash(truncate:*)"
          "Bash(nixos-install:*)"
          # Atlassian Rovo MCP tools that consume Rovo credits (unified search,
          # Teamwork Graph; overage billed by default from 2026-12-03). Every
          # sandboxed session gets sandbox-proxy's `atlassian` server, and the
          # free single-product tools cover what the skills need.
          "mcp__atlassian__search"
          "mcp__atlassian__getGraphContext"
          "mcp__atlassian__getGraphObject"
          "mcp__atlassian__addGraphContext"
          "mcp__atlassian__getTeamworkGraphContext"
        ];
        allow = [
          "Bash(npm test:*)"
          "Bash(npm run lint:*)"
          "Bash(git status:*)"
          "Bash(git diff:*)"
          "Bash(ls:*)"
          "Bash(cat:*)"
          "Bash(echo:*)"
          # graphify's code graph (see graphifyContextScript): read-only tools
          "mcp__graphify"
        ];
      };
      hooks =
        let
          cmd = command: { type = "command"; inherit command; };
        in {
          SessionStart = [
            { matcher = ""; hooks = [ (cmd "${graphifyContextScript}") ]; }
          ];
          Notification = [
            { matcher = ""; hooks = [ (cmd "${notifyScript}") ]; }
          ];
          Stop = [
            { matcher = ""; hooks = [ (cmd ''${notifyScript} "Finished responding"'') ]; }
          ];
        };
    };
    settingsFile = pkgs.writeText "claude-code-settings.json" (builtins.toJSON settings);

    # Locally-authored skills: one subdirectory per skill under ./skills,
    # each holding a SKILL.md (see modules/apps/claude/skills/README.md). Copied
    # wholesale into ~/.claude/skills/.
    skillsSource = ./skills;

    # Subagent definitions (one .md per agent under ./agents, see
    # ./agents/README.md). Copied into ~/.claude/agents/, which is fully
    # Nix-owned like ~/.claude/skills.
    agentsSource = ./agents;

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

    # graphify's Claude Code skill (SKILL.md + its references/ sidecar), from
    # the latest GitHub release. "Latest" can't be resolved in pure eval, so
    # this runs at activation: it resolves the release tag on every switch,
    # downloads only when the tag changed, and caches the result so an
    # offline switch reinstalls the last fetched version instead of dropping
    # the skill.
    graphifySkillScript = pkgs.writeShellScript "claude-code-graphify-skill" ''
      set -euo pipefail
      export PATH=${lib.makeBinPath [ pkgs.curl pkgs.gnutar pkgs.gzip pkgs.coreutils ]}
      repo="Graphify-Labs/graphify"
      cache="''${XDG_CACHE_HOME:-$HOME/.cache}/claude-code/graphify-skill"
      dest="$HOME/.claude/skills/graphify"

      latest_url="$(curl -fsSL --max-time 20 -o /dev/null -w '%{url_effective}' \
        "https://github.com/$repo/releases/latest" || true)"
      tag="''${latest_url##*/tag/}"
      if [[ "$latest_url" == */tag/* && "$tag" =~ ^[A-Za-z0-9._-]+$ ]]; then
        if [[ "$(cat "$cache/.tag" 2>/dev/null || true)" != "$tag" ]]; then
          tmp="$(mktemp -d)"
          trap 'rm -rf "$tmp"' EXIT
          if curl -fsSL --max-time 120 "https://codeload.github.com/$repo/tar.gz/refs/tags/$tag" \
              | tar -xz -C "$tmp" --strip-components=1 --wildcards \
                  '*/graphify/skill.md' '*/graphify/skills/claude/references/*' \
              && [[ -s "$tmp/graphify/skill.md" ]]; then
            mkdir -p "$tmp/out"
            cp "$tmp/graphify/skill.md" "$tmp/out/SKILL.md"
            cp -r "$tmp/graphify/skills/claude/references" "$tmp/out/references"
            echo "$tag" > "$tmp/out/.tag"
            mkdir -p "$(dirname "$cache")"
            rm -rf "$cache"
            mv "$tmp/out" "$cache"
            echo "graphify skill: installed $tag"
          else
            echo "graphify skill: failed to download $tag, keeping cached copy" >&2
          fi
        fi
      else
        echo "graphify skill: couldn't resolve the latest release, keeping cached copy" >&2
      fi

      if [[ -f "$cache/SKILL.md" ]]; then
        rm -rf "$dest"
        mkdir -p "$dest"
        cp -r "$cache/SKILL.md" "$cache/references" "$dest/"
        chmod -R u+rwX "$dest"
      fi
    '';

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

    # ~/.claude/agents is fully Nix-owned: wiped and repopulated from
    # agentsSource on every switch
    home.activation.claudeCodeAgents = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run rm -rf "$HOME/.claude/agents"
      run mkdir -p "$HOME/.claude/agents"
      run cp -r ${agentsSource}/. "$HOME/.claude/agents/"
      run rm -f "$HOME/.claude/agents/README.md"
      run chmod -R u+rwX "$HOME/.claude/agents"
    '';

    # Must run after claudeCodeSkills, which wipes ~/.claude/skills
    home.activation.claudeCodeGraphifySkill = lib.hm.dag.entryAfter [ "claudeCodeSkills" ] ''
      run ${graphifySkillScript}
    '';
  };
}
