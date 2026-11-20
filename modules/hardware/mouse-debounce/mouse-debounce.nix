_: {
  flake.nixosModules.mouseDebounce = { pkgs, ... }:
  let
    mouse-debounce = pkgs.buildGoModule {
      pname = "mouse-debounce";
      version = "0.1.0";
      src = ./src;
      vendorHash = null;
      doCheck = true;
    };
  in {
    hardware.uinput.enable = true;

    systemd.services.mouse-debounce = {
      description = "Debounce mouse buttons with worn/chattering mechanical switches";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-udevd.service" ];

      serviceConfig = {
        ExecStart = "${mouse-debounce}/bin/mouse-debounce";
        Restart = "on-failure";
        RestartSec = "2s";

        # EVIOCGRAB on any current or future /dev/input/eventN and writing /dev/uinput need root
        User = "root";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateNetwork = true;
      };
    };
  };
}
