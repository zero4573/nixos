_: {
  # Flake check of the claude-sandbox launcher: shellcheck of its scripts,
  # then claude-sandbox-test.sh, which runs claude-sandbox.sh against stub
  # podman/systemd-run/... and asserts the mount list it builds.
  #   nix build .#checks.<system>.claude-sandbox
  perSystem = { pkgs, ... }: {
    checks.claude-sandbox = pkgs.runCommand "claude-sandbox-check"
      {
        nativeBuildInputs = with pkgs; [ bash shellcheck jq git coreutils findutils gawk gnugrep gnused ];
      }
      ''
        shellcheck -s bash ${./claude-sandbox.sh} ${./claude-sandbox-test.sh}
        bash ${./claude-sandbox-test.sh} ${./claude-sandbox.sh}
        touch $out
      '';
  };
}
