_: {
  # How the tix workflow (its own flake input: commands, the plugin for
  # Claude Code and kiro, Obsidian vault setup) runs on these hosts. tix
  # knows nothing of the sandbox; this module wires the two together:
  #  * sessions run `claude` or `kiro`, which are claude-sandbox and
  #    kiro-sandbox here (modules/apps/claude, modules/apps/kiro); AGENT=<profile>
  #    picks the account (modules/apps/agents) without tix knowing
  #  * the MCP servers `tix sync` talks to are sandbox-proxy's, on the host
  #    loopback (modules/apps/sandbox-proxy), started on demand
  #  * Claude's LSP tool, which the skills can use for references and
  #    callers, comes with every sandboxed session
  #    (programs.claudeSandbox.lspServers), not from here
  #  * the tools sessions run (`tix ws`, `tix new`, ...) are on the
  #    sandbox's PATH, and TIX_* variables reach them
  #  * tix's embedding model cache ($XDG_CACHE_HOME/tix/models) is mounted
  #    read-only in every sandboxed session (programs.claudeSandbox.
  #    readOnlyPaths), so `tix vault search` finds its models; they are
  #    fetched on the host first (`tix vault model fetch`), a missing
  #    cache is skipped with a log line
  #  * SANDBOX_* set in the shell that runs `tix` reach that one
  #    session's sandbox, claude's or kiro's: sessions run in the foreground
  #    of that shell, so they inherit its environment (`SANDBOX_PORTS=3000
  #    tix start PROJ-12`); tix itself adds the folders a session needs to
  #    SANDBOX_ADD_DIRS and the model cache to SANDBOX_RO_PATHS
  #  * your session rules (sessionSettings below): what ticket and spec
  #    sessions may never do, on top of tix's own (spec
  #    sessions also keep out of the repos)
  flake.homeModules.tixSetup = { config, ... }:
  let
    # Atlassian Rovo MCP tools that consume Rovo credits (unified search,
    # Teamwork Graph; overage billed by default from 2026-12-03); the free
    # single-product tools cover what the skills need. One set per MCP
    # server name the vaults' ticket sources use.
    paidRovoTools = server: map (t: "mcp__${server}__${t}")
      [ "search" "getGraphContext" "getGraphObject" "addGraphContext" "getTeamworkGraphContext" ];
    # Built-in tools ticket work never uses: a deny naming the whole tool
    # drops its schema from the session's context (and its subagents'),
    # which keeps every ticket session's startup smaller
    unusedTools = [
      "Artifact" "ArtifactCheck" "ArtifactComments" "ArtifactData"
      "SendFeedback" "ShareOnboardingGuide"
    ];
  in {
    programs.tix = {
      enable = true;
      mcpConfig = "${config.xdg.configHome}/sandbox-proxy/mcp-host.json";
      mcpPrepare = "sandbox-proxy start mcp";

      # Ticket and spec sessions commit on their branches, signed through
      # git-ssh-broker's agent, and push them (`/tix:save` pushes the
      # feature branches) through the broker, which refuses force pushes and
      # branch/tag deletes: those, like the managed-settings denies of them
      # (claude-sandbox.nix), are your manual steps on the host. Sessions
      # never reset, force-delete branches, clean, remove the ticket
      # workspace (`tix ws rm`), nor call the paid Rovo tools. The lead does add and remove git worktrees: each task
      # runs in its own worktree under the ticket workspace's `tasks/`, and
      # once its branch is merged into the ticket branch the worktree is
      # removed and the branch ref deleted with `git update-ref -d` after an
      # ancestry check (`git branch -d` would write the main clone's
      # read-only config; -D stays denied). Their workspace settings file stays read-only
      # (the sandbox mounts Edit/Write denies read-only), so a session can't
      # relax these.
      # Ticket sessions compact by themselves just past tix's last context
      # warning (250k tokens): the PO checkpoints its board and relay at
      # the warnings (/tix:po-refresh), so nothing is lost, and tix's
      # SessionStart hook resumes it from the board afterwards
      sessionSettings.autoCompactWindow = 260000;
      sessionSettings.permissions.deny = [
        "Bash(git reset --hard:*)"
        "Bash(git branch -D:*)"
        "Bash(git clean:*)"
        "Bash(tix ws rm:*)"
        "Edit(.claude/settings.json)"
        "Write(.claude/settings.json)"
      ] ++ paidRovoTools "atlassian" ++ unusedTools;

      obsidian.vaults = [ "work" "personal" ];
    };

    # Tools sessions run themselves, on the sandbox's PATH, and the variables
    # they need (e.g. the vault a `tix claude` session works on)
    programs.claudeSandbox.extraPackages = config.programs.tix.sessionTools;
    programs.claudeSandbox.passEnv = [ "TIX_*" ];
    programs.claudeSandbox.readOnlyPaths = [ "${config.xdg.cacheHome}/tix/models" ];
    # The same in kiro sandbox sessions (modules/apps/kiro), so tix's tools
    # (tix vault search, tix ws, ...) work there too, and vaults set to
    # kiro (.workflow.json "agent": "kiro", TIX_AGENT or --agent) run their
    # sessions in it: tix renders its plugin into the workspace's .kiro/
    # and runs `kiro chat --agent tix` (the sandboxed kiro trusts all tools)
    programs.tix.kiro = "kiro";
    programs.kiroSandbox.extraPackages = config.programs.tix.sessionTools;
    programs.kiroSandbox.passEnv = [ "TIX_*" ];
    programs.kiroSandbox.readOnlyPaths = [ "${config.xdg.cacheHome}/tix/models" ];

    # `tixd work|tickets|repos`: cd into the current vault's directories
    # (`tix dir` prints them; a command can't change the shell's directory)
    programs.zsh.initContent = ''
      tixd() { local d; d="$(tix dir "$@")" && cd "$d"; }
    '';
  };
}
