_: {
  # Agent accounts ("profiles"): several claude or kiro accounts side by
  # side, each with its own home directory (config + login), picked with
  # AGENT=<profile>:
  #
  #  * agent / agent-open - run a profile's agent, sandboxed (claude, kiro)
  #       or open (claude-open, kiro-open); the profile is $AGENT, else the
  #       file's default, else its only one. With no profiles yet they run
  #       agent-configure first.
  #  * agent-configure - adds a profile by asking for its name, agent and
  #       home (default <homesDir>/<name>); --list, --default <profile>.
  #  * the claude / kiro wrappers themselves honour AGENT=<profile> of their
  #       own agent (agent-profile.sh, sourced into each), so a tool that
  #       starts a particular CLI (tix runs claude or kiro, for their
  #       CLI-specific setup) gets the account AGENT names without knowing
  #       about profiles; a profile of the other agent is left alone.
  #
  #  The profiles file (~/.config/agents/profiles.json) is yours, written by
  #  agent-configure, not by Nix. A profile's home is CLAUDE_CONFIG_DIR for
  #  claude; for kiro it is KIRO_HOME, its login in <home>/.data
  #  (XDG_DATA_HOME of kiro-open) and its sandbox state in <home>/.sandbox.
  #  Claude homes marked by agent-configure get the Nix-managed settings,
  #  skills and agents at every switch (claude-code.nix).
  flake.homeModules.agents = { config, lib, pkgs, ... }:
  let
    cfg = config.programs.agents;
    configure = pkgs.writeShellApplication {
      name = "agent-configure";
      runtimeInputs = [ pkgs.jq pkgs.coreutils pkgs.util-linux ];
      # jq filters in single quotes (the script's own directive covers it
      # standalone, not once inlined after the resolver)
      excludeShellChecks = [ "SC2016" ];
      text = ''
        # shellcheck disable=SC2088 # a literal ~, expanded by the script
        export AGENTS_HOMES=${lib.escapeShellArg cfg.homesDir}
        ${cfg.profileLib}
        ${builtins.readFile ./agent-configure.sh}
      '';
    };
    dispatcher = name: mode: pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.jq pkgs.coreutils ];
      text = ''
        export AGENTS_MODE=${mode}
        export AGENT_CONFIGURE=${lib.getExe configure}
        export AGENT_CMD_claude_sandbox=${lib.getExe' config.programs.claudeSandbox.commands.sandbox "claude"}
        export AGENT_CMD_claude_open=${lib.getExe' config.programs.claudeSandbox.commands.open "claude-open"}
        export AGENT_CMD_kiro_sandbox=${lib.getExe' config.programs.kiroSandbox.commands.sandbox "kiro"}
        export AGENT_CMD_kiro_open=${lib.getExe' config.programs.kiroSandbox.commands.open "kiro-open"}
        ${cfg.profileLib}
        ${builtins.readFile ./agent.sh}
      '';
    };
  in {
    options.programs.agents = {
      homesDir = lib.mkOption {
        type = lib.types.str;
        default = "~/.config/agents/homes";
        description = "Where agent-configure puts a new profile's home by default (<homesDir>/<profile>); ~ is expanded.";
      };
      # The profile resolver every agent wrapper includes. Internal.
      profileLib = lib.mkOption {
        type = lib.types.str;
        internal = true;
        readOnly = true;
        default = builtins.readFile ./agent-profile.sh;
        description = "agent-profile.sh, inlined into the agent wrappers.";
      };
    };

    config.home.packages = [ configure (dispatcher "agent" "sandbox") (dispatcher "agent-open" "open") ];
  };
}
