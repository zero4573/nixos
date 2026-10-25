_: {
  # How the claude-tickets workflow (its own flake input: commands, Claude
  # Code plugin, Obsidian vault setup) runs on these hosts. claude-tickets
  # knows nothing of the sandbox; this module wires the two together:
  #  * sessions run `claude`, which is claude-sandbox here
  #    (modules/apps/claude/claude-sandbox.nix)
  #  * the MCP servers `ct sync` talks to are sandbox-proxy's, on the host
  #    loopback (modules/apps/sandbox-proxy), started on demand
  #  * the code graph's containers run in aisandbox.slice, with podman
  #  * the `fff` MCP server the skills search with comes with every
  #    sandboxed session (programs.claudeSandbox.extraMcpServers), not
  #    from here
  #  * the tools sessions run (`ct ws`, `ct new`, ...) are on the
  #    sandbox's PATH, and CLAUDE_TICKETS_* variables reach them
  #  * ct's embedding model cache ($XDG_CACHE_HOME/claude-tickets/models) is mounted
  #    read-only in every sandboxed session (programs.claudeSandbox.
  #    readOnlyPaths), so `ct vault search` finds its models
  #  * your session rules (sessionSettings below): what ticket and kb
  #    sessions may never do, on top of claude-tickets' own (main clones
  #    read-only)
  flake.homeModules.claudeTicketsSetup = { config, ... }:
  let
    # Atlassian Rovo MCP tools that consume Rovo credits (unified search,
    # Teamwork Graph; overage billed by default from 2026-12-03); the free
    # single-product tools cover what the skills need. One set per MCP
    # server name the vaults' ticket sources use.
    paidRovoTools = server: map (t: "mcp__${server}__${t}")
      [ "search" "getGraphContext" "getGraphObject" "addGraphContext" "getTeamworkGraphContext" ];
  in {
    programs.claude-tickets = {
      enable = true;
      mcpConfig = "${config.xdg.configHome}/sandbox-proxy/mcp-host.json";
      mcpPrepare = "sandbox-proxy start mcp";
      container = "podman";
      systemdSlice = "aisandbox.slice";

      # Ticket and kb sessions commit on their branches (unsigned; `ct ws
      # sign` on the host), but never push, reset, force-delete branches,
      # clean, remove the ticket workspace (`ct ws rm`), nor call the paid
      # Rovo tools. The lead does add and remove git worktrees: each task
      # runs in its own worktree under the ticket workspace's `.tasks/`, and
      # once its branch is merged into the ticket branch the worktree is
      # removed and the branch deleted with `git branch -d` (merged branches
      # only; -D stays denied). Their workspace settings file stays read-only
      # (the sandbox mounts Edit/Write denies read-only), so a session can't
      # relax these.
      sessionSettings.permissions.deny = [
        "Bash(git push:*)"
        "Bash(git reset --hard:*)"
        "Bash(git branch -D:*)"
        "Bash(git clean:*)"
        "Bash(ct ws rm:*)"
        "Edit(.claude/settings.json)"
        "Write(.claude/settings.json)"
      ] ++ paidRovoTools "atlassian";

      obsidian.vaults = [ "work" "personal" ];
    };

    # Tools sessions run themselves, on the sandbox's PATH, and the variables
    # they need (e.g. the vault a `ct claude` session works on)
    programs.claudeSandbox.extraPackages = config.programs.claude-tickets.sessionTools;
    programs.claudeSandbox.passEnv = [ "CLAUDE_TICKETS_*" ];
    programs.claudeSandbox.readOnlyPaths = [ "${config.xdg.cacheHome}/claude-tickets/models" ];
  };
}
