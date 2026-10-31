_: {
  # Flake check of the agent profile scripts: shellcheck, then
  # agents-test.sh (profiles.json written by agent-configure, the agent /
  # agent-open dispatch and the wrappers' AGENT resolution, against stub
  # wrappers).
  #   nix build .#checks.<system>.agents
  perSystem = { pkgs, ... }: {
    checks.agents = pkgs.runCommand "agents-check"
      { nativeBuildInputs = with pkgs; [ bash shellcheck jq coreutils util-linux gnugrep gnused ]; }
      ''
        shellcheck -s bash ${./agent-profile.sh} ${./agent.sh} ${./agent-configure.sh} ${./agents-test.sh}
        cp ${./agent-profile.sh} agent-profile.sh
        cp ${./agent.sh} agent.sh
        cp ${./agent-configure.sh} agent-configure.sh
        bash ${./agents-test.sh} "$PWD"
        touch $out
      '';
  };
}
