_: {
  flake.homeModules.npmSandbox = { pkgs, lib, ... }:
  let
    npmSandbox = pkgs.writeShellApplication {
      name = "npm-sandbox";
      runtimeInputs = [ pkgs.podman pkgs.asdf-vm pkgs.gawk ];
      text = builtins.readFile ./npm-sandbox.sh;
    };
  in {
    home.packages = [ npmSandbox ];
    home.file.".alias".text = ''
      alias npm='npm-sandbox'
    '';
  };
}
