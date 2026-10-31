{ self, ... }: {
  # ttt (terminal editor), from nixpkgs, plus its herdr plugin and language
  # servers. The NixOS module installs the package and adds the home module
  # to the primary user.
  # ttt parses `git log -z --pretty=format:...` by NUL-separated fields, and
  # the global log.showSignature (git.nix) prepends a "Good signature" line
  # that shifts them, so every commit fails with "Could not read commit". The
  # wrapper turns it off for ttt's git calls (and so for its terminal panes).
  # It also appends the language servers and ttt-prettier to PATH, after
  # the user's own, so a gopls, typescript-language-server or dart (e.g. a
  # Flutter SDK's, matching the project) already on PATH still wins. ttt-prettier is the JS/TS formatter (see the home module):
  # the project's own node_modules/.bin/prettier, found from the file's
  # directory up, so its version and plugins apply, else nixpkgs' prettier.
  flake.nixosModules.ttt = { config, lib, pkgs, ... }:
  let
    tttPrettier = pkgs.writeShellApplication {
      name = "ttt-prettier";
      text = ''
        # ttt-prettier FILE: format stdin as FILE
        d="$(dirname "$1")"
        while [[ "$d" != / && "$d" != . ]]; do
          if [[ -x "$d/node_modules/.bin/prettier" ]]; then
            exec "$d/node_modules/.bin/prettier" --stdin-filepath "$1"
          fi
          d="$(dirname "$d")"
        done
        exec ${lib.getExe pkgs.prettier} --stdin-filepath "$1"
      '';
    };
    ttt = pkgs.symlinkJoin {
      name = "ttt-${pkgs.ttt.version}";
      paths = [ pkgs.ttt ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/ttt \
          --set GIT_CONFIG_COUNT 1 \
          --set GIT_CONFIG_KEY_0 log.showSignature \
          --set GIT_CONFIG_VALUE_0 false \
          --suffix PATH : ${lib.makeBinPath [
            pkgs.gopls
            pkgs.typescript-language-server
            pkgs.vscode-langservers-extracted
            pkgs.dart
            tttPrettier
          ]}
      '';
      inherit (pkgs.ttt) meta;
    };
  in {
    environment.systemPackages = [ ttt ];
    home-manager.users.${config.hostConfig.user.name}.imports = [ self.homeModules.ttt ];
  };

  # herdr keeps its plugin registry in ~/.config/herdr, so the plugin is
  # registered with `herdr plugin link` on every activation, pointing at the
  # herdr-plugin/ directory of the same ttt release as the package. Linking
  # (unlike `herdr plugin install`) fetches nothing and runs no build step,
  # which would otherwise curl-install a second ttt.
  #
  # ttt ships no language server configs of its own: every server is an
  # lsp.servers entry in ~/.config/ttt/settings.json. ttt rewrites that file
  # when settings change in the editor, so it can't be a read-only store
  # link; activation merges the servers below into it instead, replacing
  # those keys and keeping everything else. Formatting is the servers' too
  # (gopls: gofmt; dart format; vscode-json-language-server), except JS/TS: the
  # TypeScript server's formatter isn't prettier, so those extensions also
  # get ttt-prettier as their external formatter (Ctrl+L E, and on save
  # with editor.formatOnSave), merged into `formatters` the same way.
  flake.homeModules.ttt = { config, lib, pkgs, ... }:
  let
    plugin = "${pkgs.ttt.src}/herdr-plugin";
    herdr = lib.getExe pkgs.herdr;
    jq = lib.getExe pkgs.jq;
    settings = "${config.xdg.configHome}/ttt/settings.json";
    servers = pkgs.writeText "ttt-lsp-servers.json" (builtins.toJSON {
      go.command = [ "gopls" "serve" ];
      dart = {
        command = [ "dart" "language-server" "--protocol=lsp" ];
        languages.".dart" = "dart";
      };
      typescript = {
        command = [ "typescript-language-server" "--stdio" ];
        languages = {
          ".ts" = "typescript";
          ".tsx" = "typescriptreact";
          ".mts" = "typescript";
          ".cts" = "typescript";
          ".js" = "javascript";
          ".jsx" = "javascriptreact";
          ".mjs" = "javascript";
          ".cjs" = "javascript";
        };
      };
      json = {
        command = [ "vscode-json-language-server" "--stdio" ];
        languages = {
          ".json" = "json";
          ".jsonc" = "jsonc";
        };
      };
    });
    formatters = pkgs.writeText "ttt-formatters.json" (builtins.toJSON (lib.genAttrs
      [ "ts" "tsx" "mts" "cts" "js" "jsx" "mjs" "cjs" ]
      (_: "ttt-prettier {file}")));
  in {
    home.activation.tttHerdrPlugin = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${herdr} plugin unlink ttt.editor >/dev/null 2>&1 || true
      run ${herdr} plugin link ${plugin} >/dev/null
    '';

    home.activation.tttLspServers = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      settings=${lib.escapeShellArg settings}
      current='{}'
      [[ -e "$settings" ]] && current=$(cat "$settings")
      if merged=$(${jq} --slurpfile servers ${servers} --slurpfile formatters ${formatters} \
          '.lsp.servers = (.lsp.servers // {}) + $servers[0]
           | .formatters = (.formatters // {}) + $formatters[0]' <<<"$current"); then
        run mkdir -p "$(dirname "$settings")"
        [[ -v DRY_RUN ]] || printf '%s\n' "$merged" > "$settings"
      else
        warnEcho "ttt: $settings is not valid JSON; language servers and formatters not added"
      fi
    '';
  };
}
