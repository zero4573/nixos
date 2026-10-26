_: {
  # asdf pythons (and other from-source tools) link against nix store paths
  # that nothing roots; nix.gc then deletes them. This roots them, and
  # re-fetches the ones already gone, before every garbage collection.
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
    # Only hosts that use asdf (the vm host has no plugins, so no unit)
    config = lib.mkIf (config.programs.asdf.plugins != [ ]) {
      environment.systemPackages = [ asdfGcroots ];

      systemd.services.asdf-gcroots = {
        description = "Root the nix store paths of asdf-built tools";
        # No wantedBy: boot and every switch would wait on a network-
        # dependent oneshot. It runs as a dependency of nix-gc; the first
        # run after install is manual (UPDATES.md).
        # A failure here stops the collection that would break the tools
        before = [ "nix-gc.service" ];
        requiredBy = [ "nix-gc.service" ];
        after = [ "network-online.target" "nix-daemon.socket" ];
        wants = [ "network-online.target" ];
        environment.HOME = home;
        serviceConfig = {
          Type = "oneshot";
          User = user;
          ExecStart = lib.getExe asdfGcroots;
          # Realising can fetch many paths; allow for slow links
          TimeoutStartSec = "30min";
        };
      };
    };
  };
}
