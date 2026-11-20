_: {
  perSystem = { pkgs, self', ... }: {
    checks.claude-sandbox = pkgs.runCommand "claude-sandbox-check"
      {
        nativeBuildInputs = with pkgs; [ bash shellcheck jq git coreutils findutils gawk gnugrep gnused openssh ];
        GIT_SSH_BROKER = pkgs.lib.getExe self'.packages.git-ssh-broker;
        REVIEW_BROKER = pkgs.lib.getExe self'.packages.review-broker;
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
