_: {
  flake.homeModules.claudeCode = { config, pkgs, lib, ... }:
  let
    # herdr's hook as `herdr integration install claude` would write it into settings.json, read-only here; needs python3
    herdrHook = pkgs.writeShellScript "herdr-claude-hook" ''
      PATH=${pkgs.python3}/bin:$PATH exec ${pkgs.runtimeShell} \
        ${pkgs.herdr.src}/src/integration/assets/claude/herdr-agent-state.sh "$@"
    '';

    # herdr's colour rules compare only bare numbers, so each value goes under an ok/warn/hot token by level
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
          def bar: used as $u | ($u / 20 | round) as $n
            | ([range($n)] | map("▰") | join("")) + ([range(5 - $n)] | map("▱") | join(""))
              + " \($u | round)%";
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
            + [[(.rate_limits.five_hour | {w: "5h", at: .resets_at?}),
                (.rate_limits.seven_day | {w: "7d", at: .resets_at?})
                | select((.at // 0) > now)] | min_by(.at)
                | if . then (.w as $w | .at | countdown
                    | if . == "" then "" else "↻\($w) \(.)" end) else "" end]
          | map(if . == "" then "-" else . end) | @tsv' 2>/dev/null)
        # tab is IFS whitespace, so read would collapse empty fields
        for i in "''${!fields[@]}"; do [[ "''${fields[i]}" == - ]] && fields[i]=""; done
        line="$(printf '%s\n' "''${fields[@]}" | sed '/^$/d' | paste -sd'|' | sed 's/|/ · /g')"
        shown=("''${fields[@]}")
        for i in 1 4 7; do
          [[ -n "''${shown[i]:-}" ]] && shown[i]=$'\e[38;2;229;192;123m'"''${shown[i]}"$'\e[0m'
        done
        for i in 2 5 8; do
          [[ -n "''${shown[i]:-}" ]] && shown[i]=$'\e[1;38;2;224;108;117m'"''${shown[i]}"$'\e[0m'
        done
        printf '%s\n' "''${shown[@]}" | sed '/^$/d' | paste -sd'|' | sed 's/|/ · /g'
      fi
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
      preferredNotifChannel = "notifications_disabled";
      env.TIX_NOTIFY = "0";
      env.ENABLE_LSP_TOOL = "1";
      statusLine = { type = "command"; command = "${statusLineScript}"; refreshInterval = 60; };
      autoUpdate = false;
      attribution = { commit = ""; pr = ""; };
      includeCoAuthoredBy = false;
      cleanupPeriodDays = 90;
      systemPrompt = "if AGENTS.md exists, read it as CLAUDE.md.  Ensure that both AGENTS.md, and README.md (if it exists), are always kept up to date when a prompt changes a project";
      permissions = {
        deny = [
          "Bash(rm -rf:*)"
          "Bash(git push:*)"
          "Bash(*DROP TABLE*)"
          "Bash(truncate:*)"
          "Bash(nixos-install:*)"
        ] ++ paidRovoTools;
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
          herdrInstallerSessionStart = {
            matcher = "^(startup|resume|clear|compact|fork)$";
            hooks = [ (cmd "${herdrHook} session" // { timeout = 10; }) ];
          };
        in {
          SessionStart = [ herdrInstallerSessionStart ];
          SessionEnd = [
            { matcher = ""; hooks = [ (cmd "${statusLineScript} clear") ]; }
          ];
          PostToolUse = [
            {
              matcher = "Edit|MultiEdit|Write";
              hooks = [ (cmd "${lib.getExe' config.programs.tix.package "tix"} hook comment-check --anywhere") ];
            }
          ];
        };
    };
    paidRovoTools = map (t: "mcp__atlassian__${t}")
      [ "search" "getGraphContext" "getGraphObject" "addGraphContext" "getTeamworkGraphContext" ];

    settingsFile = pkgs.writeText "claude-code-settings.json" (builtins.toJSON settings);

    userInstructions = ./user-CLAUDE.md;

    skillsSource = ./skills;

    agentsSource = ./agents;

    # { url; ref; rev; path; only = null | [ names ]; }: pure evaluation's fetchGit needs an exact rev
    skillSources = [ ];

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
    home.packages = [ pkgs.libnotify ];

    home.activation.claudeCodeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${claudeHomes}
      for h in "''${claude_homes[@]}"; do
        mkdir -p "$h"
        run install -m 0644 ${settingsFile} "$h/settings.json"
        run install -m 0644 ${userInstructions} "$h/CLAUDE.md"
      done
    '';

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
