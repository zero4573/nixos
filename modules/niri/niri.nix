{ self, inputs, ... }:
let
  # Builds the niri `settings` attrset. `extraBinds` lets other modules
  # (onepassword, workProfile, ...) contribute additional keybinds without
  # this file needing to know about them -- see programs.niri.extraBinds in
  # hosts/options.nix.
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
      # jetbrains toolbox, started minimized (installed on all desktops).
      [ (lib.getExe pkgs.jetbrains-toolbox) "--minimize" ]
      (lib.getExe pkgs.brave)
      # ZapZap/Discord are flatpak apps (see modules/flatpak/flatpak.nix).
      [ (lib.getExe pkgs.flatpak) "run" "com.rtosta.zapzap" ]
      [ (lib.getExe pkgs.flatpak) "run" "com.discordapp.Discord" ]
      # NOTE: noctalia and vicinae are autostarted via systemd user
      # services (see their own modules). Work-only apps (1Password,
      # Teams PWA) autostart via their own modules (onepassword.nix,
      # profiles/work.nix).
    ];

    xwayland-satellite.path = lib.getExe pkgs.xwayland-satellite;

    # Don't show the "Important Hotkeys" pop-up at startup (still reachable
    # via the Super+Shift+Escape bind below).
    hotkey-overlay.skip-at-startup = _: { };

    input.keyboard.xkb.layout = "us";

    # Disable the mouse hot corner that toggles the overview (niri's default
    # is the top-left corner; whichever corner it's felt at, this turns it
    # off entirely). Overview is still reachable via its own bind below.
    gestures.hot-corners.off = _: { };

    # Tap-to-click, with clicks determined by finger count rather than
    # where on the pad you press (avoids accidental right-clicks from a
    # push near a corner/edge).
    input.touchpad = {
      tap = _: { };
      click-method = "clickfinger";
    };

    # Framework 13 2.8K panel (2880x1920) -- niri auto-picks scale 2 for a
    # panel this dense, but that halves usable real estate (effectively a
    # 1440x960 canvas). Run unscaled instead, at the panel's native pixel
    # resolution.
    outputs."eDP-1".scale = 1.0;
    layout.gaps = 5;
    layout.focus-ring = {
      width = 2;
      active-color = "darkred";
    };

    # Global rounded corners. clip-to-geometry actually clips window content
    # to the rounded shape; geometry-corner-radius also tells niri the
    # window's radius so it rounds the focus ring/border/shadow drawn around
    # it to match, automatically -- there's no separate focus-ring radius.
    window-rules = [
      {
        geometry-corner-radius = 12;
        clip-to-geometry = true;
      }
      # Floating windows use the same focus-ring settings as tiled ones by
      # default (there's no separate global "floating" section), but this
      # makes it explicit/guaranteed rather than relying on that default.
      {
        matches = [ { is-floating = true; } ];
        focus-ring = {
          width = 2;
          active-color = "darkred";
        };
      }
    ];

    # Keybinds follow CachyOS's niri scheme
    # (https://wiki.cachyos.org/configuration/desktop_environments/niri/),
    # with apps substituted for what's actually installed here: alacritty
    # (terminal), brave (browser), thunar (file manager), vicinae (app
    # launcher), and noctalia over IPC (wallpaper/control center/settings/
    # lock screen/session menu/volume/brightness/media).
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

      "Super+R"."switch-preset-column-width" = { };
      "Super+Shift+R"."switch-preset-column-width-back" = { };

      "Super+Ctrl+Shift+R"."switch-preset-window-height" = { };
      "Super+Ctrl+R"."reset-window-height" = { };

      # -- Workspace switching --
      "Super+WheelScrollDown" = _: {
        props.cooldown-ms = 150;
        content.focus-workspace-down = { };
      };
      "Super+WheelScrollUp" = _: {
        props.cooldown-ms = 150;
        content.focus-workspace-up = { };
      };
      "Super+Ctrl+WheelScrollDown" = _: {
        props.cooldown-ms = 150;
        content.move-column-to-workspace-down = { };
      };
      "Super+Ctrl+WheelScrollUp" = _: {
        props.cooldown-ms = 150;
        content.move-column-to-workspace-up = { };
      };

      "Super+WheelScrollRight"."focus-column-right" = { };
      "Super+WheelScrollLeft"."focus-column-left" = { };
      "Super+Ctrl+WheelScrollRight"."move-column-right" = { };
      "Super+Ctrl+WheelScrollLeft"."move-column-left" = { };

      "Super+Shift+WheelScrollDown"."focus-column-right" = { };
      "Super+Shift+WheelScrollUp"."focus-column-left" = { };
      "Super+Ctrl+Shift+WheelScrollDown"."move-column-right" = { };
      "Super+Ctrl+Shift+WheelScrollUp"."move-column-left" = { };

      "Super+Tab"."focus-workspace-previous" = { };

      # -- Layout controls --
      "Super+Ctrl+F"."expand-column-to-available-width" = { };
      "Super+C"."center-column" = { };
      "Super+Ctrl+C"."center-visible-columns" = { };
      "Super+Minus".set-column-width = "-10%";
      "Super+Equal".set-column-width = "+10%";
      "Super+Shift+Minus".set-window-height = "-10%";
      "Super+Shift+Equal".set-window-height = "+10%";

      # -- Modes --
      "Super+T"."toggle-window-floating" = { };
      "Super+F"."maximize-column" = { };
      "Super+Shift+F"."fullscreen-window" = { };
      "Super+W"."toggle-column-tabbed-display" = { };
      "Super+M"."maximize-window-to-edges" = { };

      # -- Screenshots (flameshot; saved to ~/Pictures/Screenshots and
      # copied to the clipboard). Flameshot has no direct equivalent of
      # niri's screenshot-window, so the window bind also opens the
      # interactive GUI -- select the window's area manually.
      "Ctrl+Shift+1" = _: {
        props.hotkey-overlay-title = "Screenshot (select area): flameshot";
        content.spawn-sh = "mkdir -p ~/Pictures/Screenshots && ${lib.getExe pkgs.flameshot} gui -p ~/Pictures/Screenshots -c";
      };
      "Ctrl+Shift+2" = _: {
        props.hotkey-overlay-title = "Screenshot (screen): flameshot";
        content.spawn-sh = "mkdir -p ~/Pictures/Screenshots && ${lib.getExe pkgs.flameshot} screen -p ~/Pictures/Screenshots -c";
      };
      "Ctrl+Shift+3" = _: {
        props.hotkey-overlay-title = "Screenshot (window): flameshot";
        content.spawn-sh = "mkdir -p ~/Pictures/Screenshots && ${lib.getExe pkgs.flameshot} gui -p ~/Pictures/Screenshots -c";
      };

      # -- Emergency escape key: disables any active keyboard shortcut
      # inhibitor, for when a fullscreen app blocks your keybinds. --
      "Super+Escape" = _: {
        props.allow-inhibiting = false;
        content.toggle-keyboard-shortcuts-inhibit = { };
      };

      # -- Exit / power --
      "Ctrl+Alt+Delete"."quit" = { };
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
  };

  perSystem = { pkgs, lib, system, ... }: {
    # Convenience/test artifact only (`nix build .#customNiri`); real hosts
    # build their own via mkNiriSettings above, with their own
    # programs.niri.extraBinds contributions merged in.
    packages.customNiri = inputs.wrapper-modules.wrappers.niri.wrap {
      inherit pkgs;
      settings = mkNiriSettings { inherit pkgs lib system; };
    };
  };
}
