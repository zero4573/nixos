{ self, ... }: {
  flake.nixosModules.herdr = { config, pkgs, ... }: {
    environment.systemPackages = [ pkgs.herdr ];
    home-manager.users.${config.hostConfig.user.name}.imports = [ self.homeModules.herdr ];
  };

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
        # herdr would record `onboarding = false` once chosen, but this file is read-only; updates come from nixpkgs
        onboarding = false;
        update = {
          version_check = false;
          manifest_check = false;
        };
        session.resume_agents_on_restore = false;
        terminal.new_cwd = "home";
        ui.prompt_new_workspace_name = true;
        ui.toast.delivery = "system";
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
        ui.sidebar.agents.rows_by_agent.kiro = [
          [ "state_icon" "machine" "workspace" "tab" ]
          [ "agent" ]
          [
            "$ctx_ok"
            { token = "$ctx_warn"; fg = "#e5c07b"; }
            { token = "$ctx_hot"; fg = "#e06c75"; bold = true; }
          ]
          [ { token = "$credits"; dim = true; } ]
          [ { token = "$usage_error"; fg = "#e06c75"; bold = true; } ]
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

    # a running herdr server keeps the config it started with
    home.activation.herdrReloadConfig = lib.hm.dag.entryAfter [ "linkGeneration" "herdrLayoutsPlugin" ] ''
      run ${herdr} server reload-config >/dev/null 2>&1 || true
    '';
  };
}
