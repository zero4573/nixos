{ self, inputs, ... }:
let
  # Named niri workspaces, in display/index order. A plain `workspaces`
  # attrset can't preserve declaration order -- Nix always iterates attrsets
  # alphabetically -- so ordered workspace blocks have to go through the
  # wrapper's`extraSettings` escape hatch (a real list) instead.
  niriWorkspaceOrder = [ "teams" "browser" ];
  niriExtraSettings = map
    (name: { workspace = _: { content = { }; props = name; }; })
    niriWorkspaceOrder;

  # Builds the niri `settings` attrset. `extraBinds` lets other modules
  # contribute additional keybinds without this file needing to know about them
  # see programs.niri.extraBinds in hosts/options.nix.
  mkNiriSettings = { pkgs, lib, system, extraBinds ? { } }:
  let
    vicinae = "${inputs.vicinae.packages.${system}.default}/bin/vicinae";
    noctaliaBin = lib.getExe pkgs.noctalia-shell;

    # Workspace focus / move-to bindings for workspaces 1..9, matching
    # CachyOS's niri keybinds (Mod+N focus, Mod+Ctrl+N move-to).
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
      [ (lib.getExe pkgs.brave) "--restore-last-session" ]
      [ (lib.getExe pkgs.flatpak) "run" "com.discordapp.Discord" "--start-minimized" ]
    ];

    spawn-sh-at-startup = [
      ''${lib.getExe pkgs.flatpak} run com.rtosta.zapzap --setSettings system/start_background true && ${lib.getExe pkgs.flatpak} run com.rtosta.zapzap''
    ];

    # For legacy X11 applications
    xwayland-satellite.path = lib.getExe pkgs.xwayland-satellite;

    outputs."eDP-1".scale = 1.0;
    hotkey-overlay.skip-at-startup = _: { };
    input.keyboard.xkb.layout = "us";

    gestures.hot-corners.off = _: { };
    input.touchpad = {
      tap = _: { };
      click-method = "clickfinger";
    };

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

      {
        matches = [
          { app-id = "^discord$"; }
          { app-id = "^com\\.rtosta\\.zapzap$"; }
        ];
        open-focused = false;
      }

      {
        matches = [ { app-id = "teams.microsoft.com"; at-startup = true; } ];
        open-on-workspace = "teams";
        open-maximized = true;
      }
      {
        matches = [ { app-id = "^brave-browser$"; at-startup = true; } ];
        open-on-workspace = "browser";
        open-maximized = true;
      }
    ];

    binds = {
      "Super+Shift+Escape"."show-hotkey-overlay" = { };

      # -- Applications --
      "Super+Return" = _: {
        props.hotkey-overlay-title = "Open Terminal: Alacritty";
        content.spawn-sh = lib.getExe pkgs.alacritty;
      };
      "Super+S" = _: {
        props.hotkey-overlay-title = "Open Control Center: noctalia";
        content.spawn-sh = "${noctaliaBin} ipc call controlCenter toggle";
      };
      "Super+Shift+L" = _: {
        props.hotkey-overlay-title = "Lock Screen: noctalia";
        content.spawn-sh = "${noctaliaBin} ipc call lockScreen lock";
      };
      "Super+X" = _: {
        props.hotkey-overlay-title = "Session Menu: noctalia";
        content.spawn-sh = "${noctaliaBin} ipc call sessionMenu toggle";
      };
      "Super+E" = _: {
        props.hotkey-overlay-title = "File Manager: Thunar";
        content.spawn-sh = lib.getExe pkgs.thunar;
      };

      # -- Vicinae extras (clipboard/power; not part of the CachyOS scheme) --
      "Super+D".spawn-sh = "${vicinae} toggle";
      "Super+V".spawn-sh = "${vicinae} vicinae://launch/clipboard/history";

      # -- Media controls --
      "XF86AudioRaiseVolume" = _: {
        props.allow-when-locked = true;
        content.spawn-sh = "${noctaliaBin} ipc call volume increase";
      };
      "XF86AudioLowerVolume" = _: {
        props.allow-when-locked = true;
        content.spawn-sh = "${noctaliaBin} ipc call volume decrease";
      };
      "XF86AudioMute" = _: {
        props.allow-when-locked = true;
        content.spawn-sh = "${noctaliaBin} ipc call volume muteOutput";
      };
      "XF86AudioMicMute" = _: {
        props.allow-when-locked = true;
        content.spawn-sh = "${noctaliaBin} ipc call volume muteInput";
      };
      "XF86AudioNext" = _: {
        props.allow-when-locked = true;
        content.spawn-sh = "${noctaliaBin} ipc call media next";
      };
      "XF86AudioPrev" = _: {
        props.allow-when-locked = true;
        content.spawn-sh = "${noctaliaBin} ipc call media previous";
      };
      "XF86AudioPlay" = _: {
        props.allow-when-locked = true;
        content.spawn-sh = "${noctaliaBin} ipc call media playPause";
      };
      "XF86AudioPause" = _: {
        props.allow-when-locked = true;
        content.spawn-sh = "${noctaliaBin} ipc call media playPause";
      };

      # -- Brightness controls --
      "XF86MonBrightnessUp" = _: {
        props.allow-when-locked = true;
        content.spawn-sh = "${noctaliaBin} ipc call brightness increase";
      };
      "XF86MonBrightnessDown" = _: {
        props.allow-when-locked = true;
        content.spawn-sh = "${noctaliaBin} ipc call brightness decrease";
      };

      # -- Window movement and focus --
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

      # -- Layout controls --
      "Super+Ctrl+F"."expand-column-to-available-width" = { };
      "Super+Minus".set-column-width = "-10%";
      "Super+Equal".set-column-width = "+10%";
      "Super+Shift+Minus".set-window-height = "-10%";
      "Super+Shift+Equal".set-window-height = "+10%";

      # -- Modes --
      "Super+T"."toggle-window-floating" = { };
      "Super+F"."maximize-column" = { };
      "Super+Shift+F"."fullscreen-window" = { };

      # -- Screenshots
      "Ctrl+Shift+1" = _: {
        props.hotkey-overlay-title = "Screenshot (select area): flameshot";
        content.spawn-sh = "mkdir -p ~/Pictures/Screenshots && ${lib.getExe pkgs.flameshot} gui -p ~/Pictures/Screenshots -c";
      };
      "Print" = _: {
        props.hotkey-overlay-title = "Screenshot (select area): flameshot";
        content.spawn-sh = "mkdir -p ~/Pictures/Screenshots && ${lib.getExe pkgs.flameshot} gui -p ~/Pictures/Screenshots -c";
      };

      # -- Emergency escape key: disables any active keyboard shortcut
      # inhibitor, for when a fullscreen app blocks your keybinds. --
      "Super+Escape" = _: {
        props.allow-inhibiting = false;
        content.toggle-keyboard-shortcuts-inhibit = { };
      };

      # -- Exit / power --
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
      # Referenced by niri key bindings below.
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

    # required for itune, without it, attempting to sign in result in a
    # error code 2605, "no internet connection"
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
