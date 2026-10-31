{ self, ... }: {
  # herdr (terminal agent multiplexer), from nixpkgs. The NixOS module
  # installs the package and adds the home module to the primary user.
  flake.nixosModules.herdr = { config, pkgs, ... }: {
    environment.systemPackages = [ pkgs.herdr ];
    home-manager.users.${config.hostConfig.user.name}.imports = [ self.homeModules.herdr ];
  };

  # ~/.config/herdr/config.toml, declared here. Herdr is the notifier for
  # agent sessions: when an agent finishes or needs you in a pane you're not
  # looking at, it sends a desktop notification with notify-send (on PATH
  # via claude-code.nix's libnotify). It knows a pane runs Claude from its
  # processes, so sandboxed sessions count too (claude-sandbox.nix names its
  # launcher `claude` for that). Claude's integration hook is in
  # claude-code.nix, since ~/.claude/settings.json is Nix-owned and
  # `herdr integration install claude` would be overwritten. Agent sessions
  # are not resumed after a server restart.
  #
  # The local.layouts plugin (herdr-layout.sh) gives two pane layouts as
  # actions: Claude | ttt over two shells, bound to prefix+a, and Claude | ttt,
  # unbound. Its manifest is generated here and linked with
  # `herdr plugin link` on every activation, like ttt's plugin. Activation
  # then reloads a running server's config, which it otherwise keeps.
  flake.homeModules.herdr = { lib, pkgs, ... }:
  let
    herdr = lib.getExe pkgs.herdr;
    layoutScript = pkgs.writeShellApplication {
      name = "herdr-layout";
      runtimeInputs = [ pkgs.herdr pkgs.jq ];
      text = builtins.readFile ./herdr-layout.sh;
    };
    layoutAction = id: title: {
      inherit id title;
      contexts = [ "workspace" ];
      command = [ (lib.getExe layoutScript) id ];
    };
    toml = pkgs.formats.toml { };
    # a real file in its own directory: herdr resolves a symlinked manifest
    # and would take its /nix/store parent as the plugin root
    layoutsPlugin = pkgs.runCommand "herdr-layouts-plugin" { } ''
      mkdir $out
      cp ${layoutsManifest} $out/herdr-plugin.toml
    '';
    layoutsManifest = toml.generate "herdr-plugin.toml" {
      id = "local.layouts";
      name = "Layouts";
      version = "0.1.0";
      min_herdr_version = "0.9.0";
      description = "Lay out the current tab: Claude beside ttt, with or without a shell";
      platforms = [ "linux" ];
      actions = [
        (layoutAction "full" "Layout: Claude | ttt over two shells")
        (layoutAction "simple" "Layout: Claude | ttt")
      ];
    };
  in {
    xdg.configFile."herdr/config.toml".source =
      toml.generate "herdr-config.toml" {
        # No startup screens: the first-run notification setup (herdr
        # would record `onboarding = false` once chosen, but this file is
        # read-only, so it showed every time), and the announcements and
        # release notes that come with herdr.dev's version and manifest
        # checks. Updates come from nixpkgs, so the checks have nothing to
        # offer, and agent detection keeps the release's bundled manifests.
        onboarding = false;
        update = {
          version_check = false;
          manifest_check = false;
        };
        session.resume_agents_on_restore = false;
        # New panes, tabs and workspaces start in ~ rather than following
        # the focused pane's cwd (which named every new workspace after
        # whatever folder that pane's shell sat in), and a new workspace
        # asks for its name
        terminal.new_cwd = "home";
        ui.prompt_new_workspace_name = true;
        ui.toast.delivery = "system";
        # Claude panes get herdr's default two rows plus one row per usage
        # item, from the tokens claude-code.nix's status line reports: the
        # context token count (yellow from 150k, red from 250k), how much of
        # the plan's 5-hour and weekly limits is used (yellow from 80%, red
        # from 95%), and the time to the sooner reset.
        # Rows with nothing reported disappear.
        ui.sidebar.agents.rows_by_agent.claude = [
          [ "state_icon" "machine" "workspace" "tab" ]
          [ "agent" ]
          [
            "$ctx_ok"
            { token = "$ctx_warn"; fg = "#e5c07b"; }
            { token = "$ctx_hot"; fg = "#e06c75"; bold = true; }
          ]
          [
            "$five_hour"
            { token = "$five_hour_warn"; fg = "#e5c07b"; }
            { token = "$five_hour_hot"; fg = "#e06c75"; bold = true; }
          ]
          [
            "$seven_day"
            { token = "$seven_day_warn"; fg = "#e5c07b"; }
            { token = "$seven_day_hot"; fg = "#e06c75"; bold = true; }
          ]
          [ { token = "$reset"; dim = true; } ]
        ];
        keys.command = [
          {
            key = "prefix+a";
            type = "plugin_action";
            command = "local.layouts.full";
            description = "layout: Claude | ttt over two shells";
          }
        ];
      };

    home.activation.herdrLayoutsPlugin = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${herdr} plugin unlink local.layouts >/dev/null 2>&1 || true
      run ${herdr} plugin link ${layoutsPlugin} >/dev/null \
        || warnEcho "herdr: couldn't link the local.layouts plugin"
    '';

    # A running herdr server keeps the config it started with; reload it so
    # a switch takes effect without restarting herdr (nothing to do, and the
    # error ignored, when no server is running)
    home.activation.herdrReloadConfig = lib.hm.dag.entryAfter [ "linkGeneration" "herdrLayoutsPlugin" ] ''
      run ${herdr} server reload-config >/dev/null 2>&1 || true
    '';
  };
}
