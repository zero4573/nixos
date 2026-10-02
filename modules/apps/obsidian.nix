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

  # Seeds the Tasks community plugin into each vault, once. Installs the
  # plugin files only if missing, and only creates community-plugins.json if
  # it doesn't exist yet.  After that, Obsidian's own in-app plugin
  # updater/toggle owns it, not Nix.
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

      seedVaultScript = vault: ''
        vault_dir="$HOME/Documents/Obsidian/${vault}"
        plugin_dir="$vault_dir/.obsidian/plugins/${pluginId}"
        if [ ! -e "$plugin_dir/main.js" ]; then
          run mkdir -p "$plugin_dir"
          run install -m 0644 ${tasksMainJs} "$plugin_dir/main.js"
          run install -m 0644 ${tasksManifest} "$plugin_dir/manifest.json"
          run install -m 0644 ${tasksStyles} "$plugin_dir/styles.css"
        fi

        community_plugins="$vault_dir/.obsidian/community-plugins.json"
        if [ ! -e "$community_plugins" ]; then
          run mkdir -p "$vault_dir/.obsidian"
          run bash -c 'echo ${lib.escapeShellArg (builtins.toJSON [ pluginId ])} > "$1"' _ "$community_plugins"
        fi
      '';
    in {
      home.activation.obsidianTasksPlugin =
        lib.hm.dag.entryAfter [ "writeBoundary" ]
          (lib.concatMapStringsSep "\n" seedVaultScript vaults);
    };
}
