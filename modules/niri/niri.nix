{ self, inputs, ... }:
let
  # Nix iterates attrsets alphabetically, so ordered workspaces go through the wrapper's extraSettings list
  niriWorkspaceOrder = [ "teams" "browser" ];
  niriExtraSettings = map
    (name: { workspace = _: { content = { }; props = name; }; })
    niriWorkspaceOrder;

  mkNiriSettings = { pkgs, lib, system, extraBinds ? { } }:
  let
    vicinae = lib.getExe pkgs.vicinae;
    noctaliaBin = lib.getExe pkgs.noctalia;

    workspaceBinds = builtins.listToAttrs (map (n: {
      name = "Super+${toString n}";
      value = { focus-workspace = n; };
    }) (lib.range 1 9));
    moveToWorkspaceBinds = builtins.listToAttrs (map (n: {
      name = "Super+Ctrl+${toString n}";
      value = { move-column-to-workspace = n; };
    }) (lib.range 1 9));
  in {
    spawn-at-startup = [
      [ (lib.getExe pkgs.jetbrains-toolbox) "--minimize" ]
      [ (lib.getExe pkgs.flatpak) "run" "com.discordapp.Discord" "--start-minimized" ]
    ];

    spawn-sh-at-startup = [
      ''${lib.getExe pkgs.flatpak} run com.rtosta.zapzap --setSettings system/start_background true && ${lib.getExe pkgs.flatpak} run com.rtosta.zapzap''

      # Brave falls back to its own popups for the whole session if it starts before noctalia owns
      # org.freedesktop.Notifications, and both start off graphical-session.target unordered
      ''
      for _ in $(seq 1 50); do
        ${pkgs.systemd}/bin/busctl --user status org.freedesktop.Notifications >/dev/null 2>&1 && break
        sleep 0.1
      done
      exec ${lib.getExe pkgs.brave} --restore-last-session
      ''
    ];

    xwayland-satellite.path = lib.getExe pkgs.xwayland-satellite;

    outputs."eDP-1".scale = 1.0;
    hotkey-overlay.skip-at-startup = _: { };
    input.keyboard.xkb.layout = "us";

    gestures.hot-corners.off = _: { };
    input.touchpad = {
      tap = _: { };
      click-method = "clickfinger";
    };

    clipboard.disable-primary = _: { };

    layout.gaps = 5;
    layout.focus-ring = {
      width = 2;
      active-color = "darkred";
    };

    window-rules = [
      {
        geometry-corner-radius = 12;
        clip-to-geometry = true;
      }

      {
        matches = [ { is-floating = true; } ];
        focus-ring = {
          width = 2;
          active-color = "darkred";
        };
      }

      # without at-startup the rule re-applies whenever Wayland remaps the window (restoring from the
      # tray), so these windows could never gain focus again
      {
        matches = [
          { app-id = "^discord$"; at-startup = true; }
          { app-id = "^com\\.rtosta\\.zapzap$"; at-startup = true; }
        ];
        open-focused = false;
      }

      {
        matches = [ { app-id = "teams.microsoft.com"; at-startup = true; } ];
        open-on-workspace = "teams";
        default-column-width = { proportion = 0.5; };
      }
      {
        matches = [ { app-id = "net.cozic.joplin_desktop"; at-startup = true; } ];
        open-on-workspace = "teams";
        default-column-width = { proportion = 0.5; };
      }
      {
        matches = [ { app-id = "^brave-browser$"; at-startup = true; } ];
        open-on-workspace = "browser";
        open-maximized = true;
      }

      # Remmina's connection windows share the main window's app-id, titled after the connection
      {
        matches = [ { app-id = "^org\\.remmina\\.Remmina$"; } ];
        excludes = [ { title = "^Remmina Remote Desktop Client$"; } ];
        open-maximized = true;
      }
    ];

    binds = {
      "Super+Shift+Escape"."show-hotkey-overlay" = { };

      "Super+Return" = _: {
        props.hotkey-overlay-title = "Open Terminal: Alacritty";
        content.spawn-sh = lib.getExe pkgs.alacritty;
      };
      "Super+S" = _: {
        props.hotkey-overlay-title = "Open Control Center: noctalia";
        content.spawn-sh = "${noctaliaBin} msg panel-toggle control-center";
      };
      "Super+Shift+L" = _: {
        props.hotkey-overlay-title = "Lock Screen: noctalia";
        content.spawn-sh = "${noctaliaBin} msg session lock";
      };
      "Super+X" = _: {
        props.hotkey-overlay-title = "Session Menu: noctalia";
        content.spawn-sh = "${noctaliaBin} msg panel-toggle session";
      };
      "Super+E" = _: {
        props.hotkey-overlay-title = "File Manager: Thunar";
        content.spawn-sh = lib.getExe pkgs.thunar;
      };

      "Super+D".spawn-sh = "${vicinae} toggle";
      "Super+V".spawn-sh = "${vicinae} vicinae://launch/clipboard/history";

      "XF86AudioRaiseVolume" = _: {
        props.allow-when-locked = true;
        content.spawn-sh = "${noctaliaBin} msg volume-up";
      };
      "XF86AudioLowerVolume" = _: {
        props.allow-when-locked = true;
        content.spawn-sh = "${noctaliaBin} msg volume-down";
      };
      "XF86AudioMute" = _: {
        props.allow-when-locked = true;
        content.spawn-sh = "${noctaliaBin} msg volume-mute";
      };
      "XF86AudioMicMute" = _: {
        props.allow-when-locked = true;
        content.spawn-sh = "${noctaliaBin} msg mic-mute";
      };
      "XF86AudioNext" = _: {
        props.allow-when-locked = true;
        content.spawn-sh = "${noctaliaBin} msg media next";
      };
      "XF86AudioPrev" = _: {
        props.allow-when-locked = true;
        content.spawn-sh = "${noctaliaBin} msg media previous";
      };
      "XF86AudioPlay" = _: {
        props.allow-when-locked = true;
        content.spawn-sh = "${noctaliaBin} msg media toggle";
      };
      "XF86AudioPause" = _: {
        props.allow-when-locked = true;
        content.spawn-sh = "${noctaliaBin} msg media toggle";
      };

      "XF86MonBrightnessUp" = _: {
        props.allow-when-locked = true;
        content.spawn-sh = "${noctaliaBin} msg brightness-up";
      };
      "XF86MonBrightnessDown" = _: {
        props.allow-when-locked = true;
        content.spawn-sh = "${noctaliaBin} msg brightness-down";
      };

      "Super+Q"."close-window" = { };

      "Super+Left"."focus-column-left" = { };
      "Super+H"."focus-column-left" = { };
      "Super+Right"."focus-column-right" = { };
      "Super+L"."focus-column-right" = { };
      "Super+Up"."focus-window-up" = { };
      "Super+K"."focus-window-up" = { };
      "Super+Down"."focus-window-down" = { };
      "Super+J"."focus-window-down" = { };

      "Super+Ctrl+Left"."move-column-left" = { };
      "Super+Ctrl+H"."move-column-left" = { };
      "Super+Ctrl+Right"."move-column-right" = { };
      "Super+Ctrl+L"."move-column-right" = { };
      "Super+Ctrl+Up"."move-window-up" = { };
      "Super+Ctrl+K"."move-window-up" = { };
      "Super+Ctrl+Down"."move-window-down" = { };
      "Super+Ctrl+J"."move-window-down" = { };

      "Super+Home"."focus-column-first" = { };
      "Super+End"."focus-column-last" = { };
      "Super+Ctrl+Home"."move-column-to-first" = { };
      "Super+Ctrl+End"."move-column-to-last" = { };

      "Super+Shift+Left"."focus-monitor-left" = { };
      "Super+Shift+Right"."focus-monitor-right" = { };
      "Super+Shift+Up"."focus-monitor-up" = { };
      "Super+Shift+Down"."focus-monitor-down" = { };

      "Super+Shift+Ctrl+Left"."move-column-to-monitor-left" = { };
      "Super+Shift+Ctrl+Right"."move-column-to-monitor-right" = { };
      "Super+Shift+Ctrl+Up"."move-column-to-monitor-up" = { };
      "Super+Shift+Ctrl+Down"."move-column-to-monitor-down" = { };
      "Super+Shift+V"."switch-focus-between-floating-and-tiling" = { };

      "Super+BracketLeft"."consume-or-expel-window-left" = { };
      "Super+BracketRight"."consume-or-expel-window-right" = { };

      "Super+Comma"."consume-window-into-column" = { };
      "Super+Period"."expel-window-from-column" = { };

      "Super+Ctrl+F"."expand-column-to-available-width" = { };
      "Super+Minus".set-column-width = "-10%";
      "Super+Equal".set-column-width = "+10%";
      "Super+Shift+Minus".set-window-height = "-10%";
      "Super+Shift+Equal".set-window-height = "+10%";

      "Super+T"."toggle-window-floating" = { };
      "Super+F"."maximize-column" = { };
      "Super+Shift+F"."fullscreen-window" = { };

      "Ctrl+Shift+1" = _: {
        props.hotkey-overlay-title = "Screenshot (select area): flameshot";
        content.spawn-sh = "mkdir -p ~/Pictures/Screenshots && ${lib.getExe pkgs.flameshot} gui -p ~/Pictures/Screenshots -c";
      };
      "Print" = _: {
        props.hotkey-overlay-title = "Screenshot (select area): flameshot";
        content.spawn-sh = "mkdir -p ~/Pictures/Screenshots && ${lib.getExe pkgs.flameshot} gui -p ~/Pictures/Screenshots -c";
      };

      "Super+Escape" = _: {
        props.allow-inhibiting = false;
        content.toggle-keyboard-shortcuts-inhibit = { };
      };

      "Super+Shift+P"."power-off-monitors" = { };
      "Super+O" = _: {
        props.repeat = false;
        content.toggle-overview = { };
      };
    } // extraBinds // workspaceBinds // moveToWorkspaceBinds;
  };
in {
  flake.nixosModules.niri = { pkgs, lib, config, ... }:
  let
    wallpaper = ../../assets/fairy-tail.jpg;
    custom-sddm-astronaut = pkgs.sddm-astronaut.override {
      embeddedTheme = "black_hole";

      themeConfig = {
        Background = "${wallpaper}";
        FormBackgroundColor = "#000000";
        HideLoginButton = "true";
      };
    };

  in {
    programs.niri = {
      enable = true;
      package = inputs.wrapper-modules.wrappers.niri.wrap {
        inherit pkgs;
        settings = mkNiriSettings {
          inherit pkgs lib;
          system = pkgs.stdenv.hostPlatform.system;
          extraBinds = config.programs.niri.extraBinds;
        };
        extraSettings = niriExtraSettings;
      };
    };

    systemd.user.services.niri.enableDefaultPath = false;

    environment.systemPackages = with pkgs; [
      bibata-cursors
      custom-sddm-astronaut
      brightnessctl
    ];

    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;
      theme = "sddm-astronaut-theme";

      package = pkgs.kdePackages.sddm;
      extraPackages = with pkgs; [
        bibata-cursors
        custom-sddm-astronaut
        kdePackages.qtmultimedia
      ];
    };

    services.gnome.gnome-keyring.enable = true;
    security.pam.services.passwd.enableGnomeKeyring = true;

    # iTunes sign-in fails with error 2605 "no internet connection" without it
    services.gnome.glib-networking.enable = true;
  };

  perSystem = { pkgs, lib, system, ... }: {
    packages.customNiri = inputs.wrapper-modules.wrappers.niri.wrap {
      inherit pkgs;
      settings = mkNiriSettings { inherit pkgs lib system; };
      extraSettings = niriExtraSettings;
    };
  };
}
