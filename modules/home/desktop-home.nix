{ inputs, ... }: {
  # Shared per-user (home-manager) config for desktop hosts.
  flake.homeModules.desktopHome = { pkgs, lib, osConfig, ... }: {
    imports = [ inputs.vicinae.homeManagerModules.default ];

    home.stateVersion = osConfig.hostConfig.stateVersion;

    # Vicinae launcher daemon (autostarted via systemd user service).
    programs.vicinae = {
      enable = true;
      systemd.enable = true;
      systemd.autoStart = true;
    };

    # Vicinae's power menu "Lock" action only calls logind's LockSession
    # D-Bus method (org.freedesktop.login1) -- it doesn't draw a lock screen
    # itself, and noctalia doesn't listen for that signal either, so without
    # this the button is a silent no-op. systemd-lock-handler bridges
    # logind's Lock/Unlock signals to `lock.target`/`unlock.target`, which we
    # hook up to noctalia's own lock screen.
    systemd.user.services.systemd-lock-handler = {
      Unit.Description = "Translate logind lock/unlock signals into lock.target/unlock.target";
      Service = {
        # Note: this package installs its binary under lib/, not bin/, so
        # lib.getExe (which assumes bin/) doesn't apply here.
        ExecStart = "${pkgs.systemd-lock-handler}/lib/systemd-lock-handler";
        Type = "notify";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    systemd.user.targets.lock.Unit.Description = "Activated by systemd-lock-handler on session lock";
    systemd.user.targets.unlock.Unit.Description = "Activated by systemd-lock-handler on session unlock";

    systemd.user.services.noctalia-lock-screen = {
      Unit.Description = "Show noctalia's lock screen on session lock";
      Service = {
        Type = "oneshot";
        ExecStart = "${lib.getExe pkgs.noctalia-shell} ipc call lockScreen lock";
      };
      Install.WantedBy = [ "lock.target" ];
    };

    programs.alacritty = {
      enable = true;
      settings = {
        window.opacity = 0.95;
        font.size = 11.0;
        scrolling.history = 10000;
      };
    };

    # Brave as the default browser for http(s)/html.
    xdg.mimeApps = {
      enable = true;
      defaultApplications = {
        "x-scheme-handler/http" = "brave-browser.desktop";
        "x-scheme-handler/https" = "brave-browser.desktop";
        "text/html" = "brave-browser.desktop";
      };
    };
  };
}
