{ self, ... }: {
  flake.nixosModules.ttt = { config, lib, pkgs, ... }:
  let
    tttPrettier = pkgs.writeShellApplication {
      name = "ttt-prettier";
      text = ''
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
        # ttt parses `git log -z --pretty=format:` by NUL-separated fields; log.showSignature (git.nix)
        # prepends a "Good signature" line that shifts them and every commit fails to read
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

  # `herdr plugin link` (unlike install) fetches and builds nothing, which would curl-install a second ttt;
  # ttt rewrites its settings.json from the editor, so it can't be a read-only store link and the servers are merged in
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
