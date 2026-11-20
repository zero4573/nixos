_: {
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
