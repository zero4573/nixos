_: {
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

    # Noctalia merges every *.toml in ~/.config/noctalia/ over its defaults and layers GUI changes from
    # ~/.local/state/noctalia/settings.toml on top, so a read-only store file keeps the Settings UI working
    config = (pkgs.formats.toml { }).generate "noctalia-config.toml" {
      theme = {
        mode = "dark";
        source = "builtin";
        builtin = "Noctalia";
      };

      bar.main = {
        position = "top";
        margin_ends = 0; # noctalia v5 insets the bar 100px from each end by default
        start = [ "tray" "workspaces" "media" ];
        center = [ "temp" "cpu-power" "cpu" "gpu" "disk" "ram" "disk-io" "net-down" "net-up" ];
        end = [
          "battery" "brightness" "network" "bluetooth" "volume"
          "clock" "notifications" "control-center"
        ];
      };

      widget = {
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

      # noctalia's graphs scroll at the fastest poll interval
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

      shell.panel.open_near_click_control_center = true;

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
    # noctalia discovers plugins under its data dir as the built-in "local" source
    xdg.dataFile."noctalia/plugins/sysmon_extra".source = ./plugins/sysmon_extra;
    # noctalia loads files alphabetically, so gui.toml (pulled back by update-noctalia-config.sh) wins over config.toml
    xdg.configFile."noctalia/gui.toml".source = ./gui.toml;

    systemd.user.services.noctalia = {
      Unit = {
        Description = "Noctalia shell (bar, notifications, wallpaper)";
        After = [ "graphical-session.target" "wireplumber.service" ];
        PartOf = [ "graphical-session.target" ];

        # noctalia's PipeWire connection goes stale (volume changes stop reaching the sink) when wireplumber restarts
        BindsTo = [ "wireplumber.service" ];
      };
      Service = {
        # noctalia picks its network backend once: without NetworkManager on the bus it talks to wpa_supplicant,
        # which polkit denies to users; a user unit can't order After= a system unit
        ExecStartPre = "${pkgs.writeShellScript "noctalia-wait-for-networkmanager" ''
          for _ in $(${pkgs.coreutils}/bin/seq 1 50); do
            ${pkgs.systemd}/bin/busctl --system status org.freedesktop.NetworkManager >/dev/null 2>&1 && break
            ${pkgs.coreutils}/bin/sleep 0.2
          done
        ''}";
        ExecStart = lib.getExe pkgs.noctalia;
        Restart = "on-failure";
      };
      # BindsTo only propagates the stop; being wanted by wireplumber brings noctalia back
      Install.WantedBy = [ "graphical-session.target" "wireplumber.service" ];
    };
  };
}
