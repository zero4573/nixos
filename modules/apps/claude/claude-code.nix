_: {
  flake.homeModules.claudeCode = { pkgs, lib, ... }:
  let
    # herdr's Claude integration (what `herdr integration install claude`
    # would add, but settings.json is Nix-owned, see claudeCodeSettings): on
    # SessionStart it reports the session id to the herdr pane it runs in,
    # which herdr needs to resume the session. Herdr's own script from the
    # same release as the package, with python3 on PATH since it needs one.
    # Outside herdr (no HERDR_* env, as in claude-sandbox) it does nothing.
    # Notifications are herdr's too: see modules/apps/herdr/herdr.nix.
    herdrHook = pkgs.writeShellScript "herdr-claude-hook" ''
      PATH=${pkgs.python3}/bin:$PATH exec ${pkgs.runtimeShell} \
        ${pkgs.herdr.src}/src/integration/assets/claude/herdr-agent-state.sh "$@"
    '';

    # Status line: the main context window's token count and how much of the
    # plan's 5-hour and weekly limits is used (as in /usage), e.g. `ctx 162k ·
    # 5h ▰▰▱▱▱ 42% · 7d ▰▰▰▰▱ 82% · ↻5h 1h23m` (the limits only for
    # subscribers; ↻ counts down to the sooner of their resets, marked with
    # its window, so statusLine.refreshInterval re-runs it every minute).
    # Printed as Claude's status line and, inside a herdr pane, reported as
    # that pane's sidebar tokens (modules/apps/herdr/herdr.nix lays them out).
    # The count and each limit go under one of three tokens by level (the
    # count: ctx_ok, ctx_warn from 150k, ctx_hot from 250k; a limit, e.g.
    # five_hour, five_hour_warn from 80% used, five_hour_hot from 95%) since
    # herdr's colour rules only compare bare numbers, and are coloured the
    # same in Claude's status line; empty values clear the others. Reported
    # only when the line changes; `clear` (SessionEnd) removes them all.
    statusLineScript = pkgs.writeShellScript "claude-code-status-line" ''
      set -uo pipefail
      if [[ "''${1:-}" == clear ]]; then
        line=""
        fields=("" "" "" "" "" "" "" "" "" "")
      else
        IFS=$'\t' read -r -a fields < <(${lib.getExe pkgs.jq} -r '
          # Claude only refreshes the limits on an API reply, so an idle
          # session still holds a window that has since reset: count it as 0% used
          def used: if (.resets_at // 0) > 0 and .resets_at <= now then 0
            else .used_percentage | if . > 100 then 100 else . end end;
          def countdown: (. - now) as $s | if $s <= 0 then ""
            elif $s >= 86400 then "\($s / 86400 | floor)d\($s % 86400 / 3600 | floor)h"
            elif $s >= 3600 then "\($s / 3600 | floor)h\($s % 3600 / 60 | floor)m"
            else "\($s / 60 | ceil)m" end;
          # filled for what is used, like /usage
          def bar: used as $u | ($u / 20 | round) as $n
            | ([range($n)] | map("▰") | join("")) + ([range(5 - $n)] | map("▱") | join(""))
              + " \($u | round)%";
          # one value as three fields (ok, warn, hot), only one of them set
          def band($v; $warn; $hot):
            if . == "" then ["", "", ""]
            elif $v >= $hot then ["", "", .]
            elif $v >= $warn then ["", ., ""]
            else [., "", ""] end;
          def limit($name): if . then (used as $u | "\($name) \(bar)" | band($u; 80; 95))
            else ["", "", ""] end;
          (.context_window.total_input_tokens // 0) as $t
          | (if $t == 0 then ""
             elif $t >= 1000 then "ctx \($t / 1000 | floor)k"
             else "ctx \($t)" end | band($t; 150000; 250000))
            + (.rate_limits.five_hour // null | limit("5h"))
            + (.rate_limits.seven_day // null | limit("7d"))
            # the sooner reset, marked with its window
            + [[(.rate_limits.five_hour | {w: "5h", at: .resets_at?}),
                (.rate_limits.seven_day | {w: "7d", at: .resets_at?})
                | select((.at // 0) > now)] | min_by(.at)
                | if . then (.w as $w | .at | countdown
                    | if . == "" then "" else "↻\($w) \(.)" end) else "" end]
          | map(if . == "" then "-" else . end) | @tsv' 2>/dev/null)
        # placeholders keep empty fields from collapsing under read
        for i in "''${!fields[@]}"; do [[ "''${fields[i]}" == - ]] && fields[i]=""; done
        line="$(printf '%s\n' "''${fields[@]}" | sed '/^$/d' | paste -sd'|' | sed 's/|/ · /g')"
        # Claude's status line takes ANSI colours (herdr's tokens stay plain):
        # warn fields in herdr's yellow, hot ones in bold red
        shown=("''${fields[@]}")
        for i in 1 4 7; do
          [[ -n "''${shown[i]:-}" ]] && shown[i]=$'\e[38;2;229;192;123m'"''${shown[i]}"$'\e[0m'
        done
        for i in 2 5 8; do
          [[ -n "''${shown[i]:-}" ]] && shown[i]=$'\e[1;38;2;224;108;117m'"''${shown[i]}"$'\e[0m'
        done
        printf '%s\n' "''${shown[@]}" | sed '/^$/d' | paste -sd'|' | sed 's/|/ · /g'
      fi
      # In claude-sandbox herdr is out of reach: the fields go, one per
      # line, to a file in a directory from the host, and the launcher in
      # the herdr pane reports them (claude-sandbox.sh)
      if [[ -n "''${SANDBOX_HERDR_DIR:-}" ]]; then
        out="$SANDBOX_HERDR_DIR/usage"
        for i in {0..9}; do printf '%s\n' "''${fields[i]:-}"; done >"$out.tmp" \
          && mv -f "$out.tmp" "$out"
        exit 0
      fi
      [[ "''${HERDR_ENV:-}" == 1 && -n "''${HERDR_PANE_ID:-}" ]] || exit 0
      state_dir="''${XDG_RUNTIME_DIR:-/tmp}/claude-herdr-usage"
      state="$state_dir/$HERDR_PANE_ID"
      [[ "$(cat "$state" 2>/dev/null)" == "$line" && "''${1:-}" != clear ]] && exit 0
      mkdir -p "$state_dir" && printf '%s' "$line" >"$state"
      tokens=()
      names=(ctx_ok ctx_warn ctx_hot five_hour five_hour_warn five_hour_hot
        seven_day seven_day_warn seven_day_hot reset)
      for i in "''${!names[@]}"; do tokens+=(--token "''${names[i]}=''${fields[i]:-}"); done
      ${lib.getExe pkgs.herdr} pane report-metadata "$HERDR_PANE_ID" \
        --source claude-usage --seq "$(date +%s%N)" "''${tokens[@]}" >/dev/null 2>&1 || true
    '';

    settings = {
      theme = "dark";
      tui = "fullscreen";
      verbose = true;
      useAutoModeDuringPlan = true;
      notifications = true;
      # Claude Code's own terminal notifications (bell / OSC) off: herdr
      # notifies (modules/apps/herdr/herdr.nix)
      preferredNotifChannel = "notifications_disabled";
      # tix' hooks desktop-notify (sticky, until dismissed) when a
      # ticket session needs you; herdr already does, so theirs are off
      env.TIX_NOTIFY = "0";
      # The LSP tool, served by claude-sandbox.nix's lspServers plugin (the
      # `lsp` skill says when to use it)
      env.ENABLE_LSP_TOOL = "1";
      statusLine = { type = "command"; command = "${statusLineScript}"; refreshInterval = 60; };
      autoUpdate = false;
      # Transcripts are what `claude --continue` resumes (e.g. a ticket
      # session restarted by `tix start`); keep them longer than the 30-day
      # default
      cleanupPeriodDays = 90;
      systemPrompt = "if AGENTS.md exists, read it as CLAUDE.md.  Ensure that both AGENTS.md, and README.md (if it exists), are always kept up to date when a prompt changes a project";
      # Ticket and spec sessions (the lead and its tix:task,
      # tix:mechanical, tix:reviewer and tix:reviewer-deep
      # subagents) add stricter rules (no reset --hard, branch -D, clean or
      # `tix ws rm`, ...) in their own .claude/settings.json
      # (modules/apps/tix.nix).
      permissions = {
        deny = [
          "Bash(rm -rf:*)"
          # On the host (claude-open) pushing stays denied: there it would
          # use your full SSH agent. The sandbox lifts it (its managed
          # settings), pushing through git-ssh-broker.
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
        ];
      };
      hooks =
        let
          cmd = command: { type = "command"; inherit command; };
        in {
          SessionStart = [
            # matcher and timeout as herdr's installer writes them
            {
              matcher = "^(startup|resume|clear|compact|fork)$";
              hooks = [ (cmd "${herdrHook} session" // { timeout = 10; }) ];
            }
          ];
          SessionEnd = [
            { matcher = ""; hooks = [ (cmd "${statusLineScript} clear") ]; }
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
          run cp -r ${root}/. "$h/skills/"
        ''
      else
        lib.concatMapStrings (name: ''
          run cp -r ${root}/${name} "$h/skills/${name}"
        '') s.only
    ) skillSources;

    # The Claude config dirs Nix keeps current: ~/.claude, and every claude
    # profile home agent-configure made (modules/apps/agents: listed in
    # ~/.config/agents/profiles.json and marked with .agent-profile), so
    # AGENT=<profile> sessions get the same settings, skills and agents
    claudeHomes = ''
      claude_homes=("$HOME/.claude")
      profiles="''${XDG_CONFIG_HOME:-$HOME/.config}/agents/profiles.json"
      if [[ -f "$profiles" ]]; then
        while IFS= read -r h; do
          case "$h" in "~"|"~/"*) h="$HOME''${h#\~}" ;; esac
          [[ "$h" == /* && "$h" != "$HOME/.claude" && -f "$h/.agent-profile" ]] && claude_homes+=("$h")
        done < <(${lib.getExe pkgs.jq} -r '.profiles // {} | .[] | select(.agent? == "claude") | .home? // empty | strings' "$profiles" 2>/dev/null || true)
      fi
    '';
  in {
    # notify-send on PATH for tix's notification hook (and herdr's)
    home.packages = [ pkgs.libnotify ];

    home.activation.claudeCodeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${claudeHomes}
      for h in "''${claude_homes[@]}"; do
        mkdir -p "$h"
        run install -m 0644 ${settingsFile} "$h/settings.json"
      done
    '';

    # <home>/skills is fully Nix-owned: wiped and repopulated from
    # skillsSource + skillSources on every switch
    home.activation.claudeCodeSkills = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${claudeHomes}
      for h in "''${claude_homes[@]}"; do
        run rm -rf "$h/skills"
        run mkdir -p "$h/skills"
        run cp -r ${skillsSource}/. "$h/skills/"
        ${skillCopyCommands}
        run chmod -R u+rwX "$h/skills"
      done
    '';

    # <home>/agents is fully Nix-owned: wiped and repopulated from
    # agentsSource on every switch
    home.activation.claudeCodeAgents = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${claudeHomes}
      for h in "''${claude_homes[@]}"; do
        run rm -rf "$h/agents"
        run mkdir -p "$h/agents"
        run cp -r ${agentsSource}/. "$h/agents/"
        run rm -f "$h/agents/README.md"
        run chmod -R u+rwX "$h/agents"
      done
    '';
  };
}
