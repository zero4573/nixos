_: {
  # Flake check of the claude-sandbox launcher: shellcheck of its scripts,
  # then claude-sandbox-test.sh, which runs claude-sandbox.sh against stub
  # podman/systemd-run/... and asserts the mount list it builds;
  # claude-sandbox-self-check-test.sh does the same for the self-check command.
  #   nix build .#checks.<system>.claude-sandbox
  # The launcher test runs with the real git-ssh-broker (its socket and agent
  # cases need one).
  perSystem = { pkgs, self', ... }: {
    checks.claude-sandbox = pkgs.runCommand "claude-sandbox-check"
      {
        nativeBuildInputs = with pkgs; [ bash shellcheck jq git coreutils findutils gawk gnugrep gnused openssh ];
        GIT_SSH_BROKER = pkgs.lib.getExe self'.packages.git-ssh-broker;
      }
      ''
        shellcheck -s bash ${./claude-sandbox.sh} ${./claude-sandbox-test.sh} \
          ${./claude-sandbox-self-check.sh} ${./claude-sandbox-self-check-test.sh}
        bash ${./claude-sandbox-test.sh} ${./claude-sandbox.sh}
        bash ${./claude-sandbox-self-check-test.sh} ${./claude-sandbox-self-check.sh}
        touch $out
      '';
  };
}
