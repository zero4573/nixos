_: {
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
