_: {
  # Obsidian's Flathub manifest (flathub/md.obsidian.Obsidian) requests
  # --filesystem=home plus /mnt, /run/media, /media, a Discord-RPC socket dir,
  # read-only gnupg, read-only fonts, and a persisted ~/.ssh. Revoke all of
  # that and scope it down to just the vault folder.
  flake.nixosModules.obsidian = { ... }: {
    services.flatpak.packages = [ "md.obsidian.Obsidian" ];

    services.flatpak.overrides.settings."md.obsidian.Obsidian".Context = {
      filesystems = [
        "!home"
        "!/mnt"
        "!/run/media"
        "!/media"
        "!xdg-run/app/com.discordapp.Discord"
        "!xdg-run/gnupg"
        "!~/.local/share/fonts"
        "xdg-documents/Obsidian:create"
      ];
      sockets = [ "wayland" "fallback-x11" "pulseaudio" "!ssh-auth" ];
      persistent = [ "!~/.ssh" ];
    };
  };

  # Per vault:
  #  * Tasks community plugin: seeded once. Installs the plugin files only if
  #    missing, and only creates community-plugins.json if it doesn't exist
  #    yet.  After that, Obsidian's own in-app plugin updater/toggle owns it.
  #  * Tasks plugin settings: enforced. ./tasks-settings.json is the source of
  #    truth, written to every vault's data.json on every switch -- changes
  #    made in Obsidian's settings UI are reset unless copied back here:
  #      cp ~/Documents/Obsidian/<vault>/.obsidian/plugins/obsidian-tasks-plugin/data.json \
  #        modules/apps/obsidian/tasks-settings.json
  #  * Minimal theme (kepano): seeded once, and selected only if the vault
  #    hasn't picked a theme, so in-app theme changes/updates stick.
  flake.homeModules.obsidian = { lib, pkgs, ... }:
    let
      vaults = [ "work" "personal" ];
      pluginId = "obsidian-tasks-plugin";

      # obsidian-tasks-group/obsidian-tasks release 8.4.0. Bump the version +
      # the three sha256s together when updating (nix-prefetch-url <url>).
      tasksVersion = "8.4.0";
      tasksAsset = name: sha256: pkgs.fetchurl {
        url = "https://github.com/obsidian-tasks-group/obsidian-tasks/releases/download/${tasksVersion}/${name}";
        inherit sha256;
      };
      tasksMainJs = tasksAsset "main.js" "1yj83saffq2sxm9mqy9hricicznjkjca4zir0qd7rvizrqxk7qy1";
      tasksManifest = tasksAsset "manifest.json" "0gy3czl5jqik5ddk654d2m1l5yybnsv1d7gwriqdvjx9dcagm729";
      tasksStyles = tasksAsset "styles.css" "0pck54nfgyxyaiiyvfhy3132alszd65x2ldjk5c2n5kl7cysab1v";

      # kepano/obsidian-minimal release 9.0.2 -- the newest whose
      # minAppVersion (1.13.0) the Flathub Obsidian (1.13.7) satisfies; 9.1.x
      # needs 1.14. Bump the version + both sha256s together
      # (nix-prefetch-url <url>).
      minimalVersion = "9.0.2";
      minimalAsset = name: sha256: pkgs.fetchurl {
        url = "https://github.com/kepano/obsidian-minimal/releases/download/${minimalVersion}/${name}";
        inherit sha256;
      };
      minimalCss = minimalAsset "theme.css" "0pvsgxjr9f98knvfmgm8is37qz6m3d0v1dgag4lcirn6lm7xhx49";
      minimalManifest = minimalAsset "manifest.json" "0dh5d28fin0gq2dnn2gf9xfhbg3j6n9pfkbvsm5awbma0a8r7ji2";

      # Sets cssTheme in an appearance.json (keeping its other keys) unless
      # a theme is already chosen
      selectThemeIfUnset = pkgs.writeShellScript "obsidian-select-theme" ''
        set -eu
        file="$1" theme="$2"
        current="$(cat "$file" 2>/dev/null || true)"
        [ -n "$current" ] || current='{}'
        if [ "$(${lib.getExe pkgs.jq} -r '.cssTheme // ""' <<< "$current")" = "" ]; then
          ${lib.getExe pkgs.jq} --arg t "$theme" '.cssTheme = $t' <<< "$current" > "$file.tmp"
          mv "$file.tmp" "$file"
        fi
      '';

      seedVaultScript = vault: ''
        vault_dir="$HOME/Documents/Obsidian/${vault}"
        plugin_dir="$vault_dir/.obsidian/plugins/${pluginId}"
        if [ ! -e "$plugin_dir/main.js" ]; then
          run mkdir -p "$plugin_dir"
          run install -m 0644 ${tasksMainJs} "$plugin_dir/main.js"
          run install -m 0644 ${tasksManifest} "$plugin_dir/manifest.json"
          run install -m 0644 ${tasksStyles} "$plugin_dir/styles.css"
        fi

        run install -m 0644 ${./tasks-settings.json} "$plugin_dir/data.json"

        community_plugins="$vault_dir/.obsidian/community-plugins.json"
        if [ ! -e "$community_plugins" ]; then
          run mkdir -p "$vault_dir/.obsidian"
          run bash -c 'echo ${lib.escapeShellArg (builtins.toJSON [ pluginId ])} > "$1"' _ "$community_plugins"
        fi

        theme_dir="$vault_dir/.obsidian/themes/Minimal"
        if [ ! -e "$theme_dir/theme.css" ]; then
          run mkdir -p "$theme_dir"
          run install -m 0644 ${minimalCss} "$theme_dir/theme.css"
          run install -m 0644 ${minimalManifest} "$theme_dir/manifest.json"
        fi
        run ${selectThemeIfUnset} "$vault_dir/.obsidian/appearance.json" Minimal
      '';
    in {
      home.activation.obsidianVaults =
        lib.hm.dag.entryAfter [ "writeBoundary" ]
          (lib.concatMapStringsSep "\n" seedVaultScript vaults);
    };
}
