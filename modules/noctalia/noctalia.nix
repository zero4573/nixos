_: {
  # Feeds the sysmon_extra cpu_power widget: samples the root-only RAPL energy
  # counter and publishes a coarse wattage history to /run/cpu-power/watts
  # (./cpu-power.sh).
  flake.nixosModules.noctalia = { pkgs, ... }: {
    systemd.services.cpu-power = {
      description = "Publish CPU package power for the noctalia bar";
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "/sys/class/powercap/intel-rapl:0/energy_uj";
      path = [ pkgs.coreutils ];
      serviceConfig = {
        ExecStart = "${pkgs.bash}/bin/bash ${./cpu-power.sh} /run/cpu-power/watts";
        Restart = "on-failure";
        DynamicUser = true;
        # Just enough to read energy_uj; nothing else is reachable
        AmbientCapabilities = [ "CAP_DAC_READ_SEARCH" ];
        CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
        RuntimeDirectory = "cpu-power";
        RuntimeDirectoryMode = "0755";
        UMask = "0022";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateNetwork = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = "none";
        SystemCallFilter = [ "@system-service" ];
      };
    };
  };

  flake.homeModules.noctalia = { pkgs, lib, osConfig, ... }:
  let
    assets = ../../assets;

    # Noctalia v5 merges every *.toml in ~/.config/noctalia/ over its built-in
    # defaults, then layers GUI changes from ~/.local/state/noctalia/settings.toml
    # on top -- so this file can stay read-only in the store and the Settings UI
    # still works. Only the declarative baseline lives here; tweak the rest in
    # the GUI. See docs/user/configuration in the noctalia source.
    config = (pkgs.formats.toml { }).generate "noctalia-config.toml" {
      theme = {
        mode = "dark";
        source = "builtin";
        builtin = "Noctalia";
      };

      bar.main = {
        position = "top";
        margin_ends = 0; # v5 insets the bar 100px from each end by default
        start = [ "tray" "workspaces" "media" ];
        center = [ "temp" "cpu-power" "cpu" "gpu" "disk" "ram" "disk-io" "net-down" "net-up" ];
        end = [
          "battery" "brightness" "network" "bluetooth" "volume"
          "clock" "notifications" "control-center"
        ];
      };

      # Each sysmon widget shows one stat; named entries let several coexist
      widget = {
        # ./plugins/sysmon_extra
        cpu-power.type = "local/sysmon_extra:cpu_power";
        disk-io.type = "local/sysmon_extra:disk_io";
        cpu = { type = "sysmon"; stat = "cpu_usage"; };
        gpu = { type = "sysmon"; stat = "gpu_usage"; };
        disk = { type = "sysmon"; stat = "disk_used_pct"; path = "/"; };
        ram = { type = "sysmon"; stat = "ram_used"; };
        net-down = {
          type = "sysmon";
          stat = "net_rx";
          interface = osConfig.hostConfig.wifiInterface;
        };
        net-up = {
          type = "sysmon";
          stat = "net_tx";
          interface = osConfig.hostConfig.wifiInterface;
        };
      };

      plugins.enabled = [ "local/sysmon_extra" ];

      # Graphs scroll at the fastest interval; keep every graphed group on it
      # (disk stays at its 10s default, it's shown as a number)
      system.monitor = {
        cpu_poll_seconds = 2;
        gpu_poll_seconds = 2;
        memory_poll_seconds = 2;
        network_poll_seconds = 2;
      };

      wallpaper = {
        enabled = true;
        fill_mode = "crop";
        directory = "${assets}";
        transition_duration = 1500;
        default.path = "${assets}/fairy-tail.jpg";
      };

      # Wifi, bluetooth, volume etc. all open control-center tabs; without
      # this they drop down from the middle of the bar, not under the widget
      shell.panel.open_near_click_control_center = true;

      # Volume/brightness/media-track popups default to top_center; put them
      # in the corner with the notification toasts (which default top_right)
      osd.position = "top_right";

      location.address = "Toronto, ON";
      weather = {
        enabled = true;
        unit = "celsius";
      };
    };
  in {
    home.packages = [ pkgs.noctalia ];

    xdg.configFile."noctalia/config.toml".source = config;
    # Plugins under the data dir are discovered as the built-in "local" source
    xdg.dataFile."noctalia/plugins/sysmon_extra".source = ./plugins/sysmon_extra;
    # GUI changes pulled back into the repo by update-noctalia-config.sh.
    # Files load alphabetically, so this layers over config.toml above: a key
    # set in both takes this file's value until it's deleted from here.
    xdg.configFile."noctalia/gui.toml".source = ./gui.toml;

    systemd.user.services.noctalia = {
      Unit = {
        Description = "Noctalia shell (bar, notifications, wallpaper)";
        After = [ "graphical-session.target" "wireplumber.service" ];
        PartOf = [ "graphical-session.target" ];

        # Noctalia's PipeWire connection (volume control in particular) can
        # go stale if wireplumber restarts out from under it -- it keeps
        # animating its own volume slider without the change actually
        # reaching the real sink, since its cached default-node reference
        # no longer matches. Bind to wireplumber so a restart there always
        # gives noctalia a fresh connection instead of a silently stale one.
        BindsTo = [ "wireplumber.service" ];
      };
      Service = {
        # Noctalia picks its network backend once at startup: if NetworkManager
        # isn't on the system bus yet it falls back to talking to wpa_supplicant
        # directly, which polkit denies to users, and stays there -- no wifi
        # list, no VPNs. A user unit can't order After= a system unit, so wait
        # (briefly, so a missing NetworkManager can't block the shell) for it.
        ExecStartPre = "${pkgs.writeShellScript "noctalia-wait-for-networkmanager" ''
          for _ in $(${pkgs.coreutils}/bin/seq 1 50); do
            ${pkgs.systemd}/bin/busctl --system status org.freedesktop.NetworkManager >/dev/null 2>&1 && break
            ${pkgs.coreutils}/bin/sleep 0.2
          done
        ''}";
        ExecStart = lib.getExe pkgs.noctalia;
        Restart = "on-failure";
      };
      # BindsTo only propagates the stop; being wanted by wireplumber is what
      # brings noctalia back when wireplumber starts again
      Install.WantedBy = [ "graphical-session.target" "wireplumber.service" ];
    };
  };
}
