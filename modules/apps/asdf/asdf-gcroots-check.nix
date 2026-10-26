_: {
  # Flake check of asdf-gcroots: shellcheck, then asdf-gcroots-test.sh, which
  # runs the script against a fake ASDF_DATA_DIR and a stub nix-store, under
  # a PATH of the stubs plus exactly the unit's runtimeInputs (no sh).
  #   nix build .#checks.<system>.asdf-gcroots
  perSystem = { pkgs, ... }: {
    checks.asdf-gcroots = pkgs.runCommand "asdf-gcroots-check"
      {
        nativeBuildInputs = [ pkgs.bash pkgs.shellcheck ] ++ import ./_runtime-inputs.nix pkgs;
        ASDF_TEST_PATH_DIRS = pkgs.lib.makeBinPath (import ./_runtime-inputs.nix pkgs);
      }
      ''
        shellcheck -s bash ${./asdf-gcroots.sh} ${./asdf-gcroots-test.sh}
        bash ${./asdf-gcroots-test.sh} ${./asdf-gcroots.sh}
        touch $out
      '';
  };
}
