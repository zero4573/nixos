_: {
  flake.nixosModules.asdfGcroots = { pkgs, config, lib, ... }:
  let
    user = config.hostConfig.user.name;
    home = config.users.users.${user}.home;
    asdfGcroots = pkgs.writeShellApplication {
      name = "asdf-gcroots";
      runtimeInputs = [ config.nix.package ] ++ import ./_runtime-inputs.nix pkgs;
      text = builtins.readFile ./asdf-gcroots.sh;
    };
  in {
    config = lib.mkIf (config.programs.asdf.plugins != [ ]) {
      environment.systemPackages = [ asdfGcroots ];

      systemd.services.asdf-gcroots = {
        description = "Root the nix store paths of asdf-built tools";
        before = [ "nix-gc.service" ];
        requiredBy = [ "nix-gc.service" ];
        after = [ "network-online.target" "nix-daemon.socket" ];
        wants = [ "network-online.target" ];
        environment.HOME = home;
        serviceConfig = {
          Type = "oneshot";
          User = user;
          ExecStart = lib.getExe asdfGcroots;
          TimeoutStartSec = "30min";
        };
      };
    };
  };
}
