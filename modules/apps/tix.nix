_: {
  flake.homeModules.tixSetup = { config, pkgs, ... }:
  let
    kiroGoCacheEnv = "GOPATH GOMODCACHE GOCACHE";
    tixAgent = name: passEnv: pkgs.writeShellScript "tix-${name}" ''
      export SANDBOX_GIT_AUTOSIGN=0
      ${if passEnv == "" then "" else ''export SANDBOX_PASS_ENV="''${SANDBOX_PASS_ENV:+$SANDBOX_PASS_ENV }${passEnv}"''}
      exec ${name} "$@"
    '';
    paidRovoTools = server: map (t: "mcp__${server}__${t}")
      [ "search" "getGraphContext" "getGraphObject" "addGraphContext" "getTeamworkGraphContext" ];
    # Claude Code drops a tool's schema from the session's context when a deny names the whole tool
    unusedTools = [
      "Artifact" "ArtifactCheck" "ArtifactComments" "ArtifactData"
      "SendFeedback" "ShareOnboardingGuide"
    ];
  in {
    programs.tix = {
      enable = true;
      mcpConfig = "${config.xdg.configHome}/sandbox-proxy/mcp-host.json";
      mcpPrepare = "sandbox-proxy start mcp";

      sessionSettings.autoCompactWindow = 200000;
      sessionSettings.permissions.allow = [
        "Bash(tix ws cleanup:*)"
        "Bash(tix ws resign:*)"
        "Bash(tix board:*)"
      ];
      sessionSettings.permissions.deny = [
        "Bash(git reset --hard:*)"
        "Bash(git branch -D:*)"
        "Bash(git clean:*)"
        "Bash(tix ws rm:*)"
        "Edit(.claude/settings.json)"
        "Write(.claude/settings.json)"
      ] ++ paidRovoTools "atlassian" ++ unusedTools;

      obsidian.vaults = [ "work" "personal" ];

      claude = "${tixAgent "claude" ""}";
    };

    programs.claudeSandbox.extraPackages = config.programs.tix.sessionTools ++ [ pkgs.powershell ];
    programs.claudeSandbox.passEnv = [ "TIX_*" ];
    programs.claudeSandbox.readOnlyPaths = [ "${config.xdg.cacheHome}/tix/models" ];
    programs.tix.kiro = "${tixAgent "kiro" kiroGoCacheEnv}";
    programs.kiroSandbox.extraPackages = config.programs.tix.sessionTools ++ [ pkgs.powershell ];
    programs.kiroSandbox.passEnv = [ "TIX_*" ];
    programs.kiroSandbox.readOnlyPaths = [ "${config.xdg.cacheHome}/tix/models" ];

    programs.zsh.initContent = ''
      tixd() { local d; d="$(tix dir "$@")" && cd "$d"; }
    '';
  };
}
