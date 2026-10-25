_: {
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
        center = [ "cpu" "gpu" "disk" "ram" "net-down" "net-up" ];
        end = [
          "battery" "brightness" "network" "bluetooth" "volume"
          "clock" "notifications" "control-center"
        ];
      };

      # Each sysmon widget shows one stat; named entries let several coexist
      widget = {
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

      location.address = "Toronto, ON";
      weather = {
        enabled = true;
        unit = "celsius";
      };
    };
  in {
    home.packages = [ pkgs.noctalia ];

    xdg.configFile."noctalia/config.toml".source = config;
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
