{ self, inputs, ... }: {
  perSystem = { pkgs, ... }:
  let
    assets = ../../assets;
    wallpaper = ../../assets/fairy-tail.jpg;

  in {
    packages.customNoctalia = inputs.wrapper-modules.wrappers.noctalia-shell.wrap {
      inherit pkgs;

      settings =
        (builtins.fromJSON
          (builtins.readFile ./noctalia.json)).settings // {
            wallpaper = {
              enabled = true;
              directory = "${assets}";
            };
          };
    };
  };
}
