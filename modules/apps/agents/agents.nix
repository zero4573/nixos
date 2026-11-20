_: {
  flake.homeModules.agents = { config, lib, pkgs, ... }:
  let
    cfg = config.programs.agents;
    configure = pkgs.writeShellApplication {
      name = "agent-configure";
      runtimeInputs = [ pkgs.jq pkgs.coreutils pkgs.util-linux ];
      # SC2016: agent-configure.sh's own directive is lost once inlined after the resolver
      excludeShellChecks = [ "SC2016" "SC2329" ];
      text = ''
        # shellcheck disable=SC2088 # a literal ~, expanded by the script
        export AGENTS_HOMES=${lib.escapeShellArg cfg.homesDir}
        ${builtins.readFile ./agent-profile.sh}
        ${builtins.readFile ./agent-configure.sh}
      '';
    };
    dispatcher = name: mode: pkgs.writeShellApplication {
      inherit name;
      # the resolver's functions it doesn't call (agent_profile, ...)
      excludeShellChecks = [ "SC2329" ];
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
      profileLib = lib.mkOption {
        type = lib.types.str;
        internal = true;
        readOnly = true;
        default = ''
          export AGENT_CONFIGURE=${lib.getExe configure}
          ${builtins.readFile ./agent-profile.sh}
        '';
        description = "agent-profile.sh, inlined into the agent wrappers.";
      };
    };

    config.home.packages = [ configure (dispatcher "agent" "sandbox") (dispatcher "agent-open" "open") ];
  };
}
