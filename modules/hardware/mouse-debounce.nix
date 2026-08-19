_: {
  flake.nixosModules.mouseDebounce = { pkgs, ... }:
  let
    # Hand-written (see ./mouse-debounce/) rather than a vendored third-party
    # tool: it runs as root and grabs raw input devices, so we wanted every
    # line auditable rather than trusting an obscure external project with
    # that level of access. Talks to the kernel's evdev/uinput ioctl ABI
    # directly -- no libevdev, no external Go modules.
    mouse-debounce = pkgs.buildGoModule {
      pname = "mouse-debounce";
      version = "0.1.0";
      src = ./mouse-debounce;
      vendorHash = null;
      doCheck = true;
    };
  in {
    # Provides /dev/uinput, which the daemon needs to create its debounced
    # virtual mouse.
    hardware.uinput.enable = true;

    # Grabs every external mouse (built-in trackpads are excluded, see
    # classifyDevice in ./mouse-debounce/evdev.go) and re-emits its events
    # through a virtual device. Every button release is held back for 50ms;
    # if a press for that same button arrives before then, both are
    # discarded -- covering both a worn switch's double-click bounce right
    # at the press/release edge, and a spurious mid-hold dropout further
    # into a long press (a drag or click that otherwise randomly "lets go").
    # See ./mouse-debounce/debounce.go for the state machine.
    systemd.services.mouse-debounce = {
      description = "Debounce mouse buttons with worn/chattering mechanical switches";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-udevd.service" ];

      serviceConfig = {
        ExecStart = "${mouse-debounce}/bin/mouse-debounce";
        Restart = "on-failure";
        RestartSec = "2s";

        # Needs root: EVIOCGRAB on arbitrary/future /dev/input/eventN nodes
        # plus write access to /dev/uinput. Hardened as far as that
        # requirement allows.
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
