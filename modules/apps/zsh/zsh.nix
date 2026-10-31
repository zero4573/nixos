_: {
  flake.nixosModules.zsh = { pkgs, config, ... }: {
    programs.zsh.enable = true;
    users.users.${config.hostConfig.user.name}.shell = pkgs.zsh;
  };

  flake.homeModules.zsh = { pkgs, lib, asdfPlugins, asdfVersions, ... }: {
    home.packages = [ pkgs.asdf-vm ];

    # Install all asdf plugin
    home.activation.asdfPlugins = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      let
        asdf = lib.getExe pkgs.asdf-vm;
      in ''
        # The activation script's PATH is a minimal, curated one (no git) --
        # `asdf plugin add` shells out to git to clone the plugin repo, so it
        # needs to be added explicitly.
        export PATH="${pkgs.git}/bin:$PATH"
      ''
      + lib.concatMapStringsSep "\n" (name: ''
        run ${asdf} plugin add ${lib.escapeShellArg name} || true
      '') asdfPlugins
    );

    # Pre-install the pinned asdf versions (programs.asdf.versions). A user
    # service rather than activation: a download like Flutter's SDK
    # (~800 MB) can outlast home-manager's 5 min activation timeout. Its
    # script names the versions, so adding one restarts it on switch; it
    # skips installed ones and retries on failure (e.g. no network yet).
    systemd.user.services.asdf-install = lib.mkIf (asdfVersions != { }) {
      Unit.Description = "Install pinned asdf tool versions";
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "5min";
        TimeoutStartSec = "1h";
        ExecStart = lib.getExe (pkgs.writeShellApplication {
          name = "asdf-install";
          # What asdf and the plugins' install scripts shell out to
          runtimeInputs = with pkgs; [
            asdf-vm git curl jq gnutar xz gzip unzip coreutils gnused gnugrep findutils which
          ];
          text = lib.concatStrings (lib.mapAttrsToList (name: versions:
            lib.concatMapStrings (version: ''
              if [[ ! -d "''${ASDF_DATA_DIR:-$HOME/.asdf}/installs/"${lib.escapeShellArg "${name}/${version}"} ]]; then
                asdf plugin add ${lib.escapeShellArg name} || true
                asdf install ${lib.escapeShellArg name} ${lib.escapeShellArg version}
              fi
            '') versions) asdfVersions);
        });
      };
      Install.WantedBy = [ "default.target" ];
    };

    # For fuzzy searching
    programs.fzf = {
      enable = true;
      enableZshIntegration = true;
    };
    programs.zoxide = {
      enable = true;
      enableZshIntegration = true;
    };

    home.file.".alias".text = ''
      # Shell aliases.

      alias ls='ls --color'
      alias ll='ls -ltra --color'
      alias vim='nvim'
      alias vi='nvim'
      alias p='cd ~/Projects'
      alias cd='z'
    '';

    home.file.".p10k.zsh".source = ./p10k.zsh;

    programs.zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestion = {
        enable = true;
        strategy = [ "history" "completion" ];
      };
      initContent = lib.mkMerge [
        # Load the theme as early as possible, before anything else prints --
        # required for powerlevel10k's instant-prompt feature to work.
        (lib.mkBefore ''
          source "${pkgs.zsh-powerlevel10k}/share/zsh-powerlevel10k/powerlevel10k.zsh-theme"
        '')
        ''
          # Force emacs bindings so Ctrl+A/Ctrl+E etc. keep working regardless
          # of $EDITOR.
          bindkey -e

          # Alacritty sends xterm-style CSI sequences for Alt+Left/Right
          # (`\e[1;3D`/`\e[1;3C`) and Ctrl+Left/Right (`\e[1;5D`/`\e[1;5C`),
          # which aren't in zsh's default emacs keymap, this binds them to
          # word-jump explicitly.
          bindkey '^[[1;3D' backward-word
          bindkey '^[[1;3C' forward-word
          bindkey '^[[1;5D' backward-word
          bindkey '^[[1;5C' forward-word

          source "${pkgs.asdf-vm}/etc/profile.d/asdf-prepare.sh"
          [ -f "$HOME/.alias" ] && source "$HOME/.alias"
          [ -f "$HOME/.custom" ] && source "$HOME/.custom"

          # Grey start time + duration for every command.
          source ${./cmd-timing.zsh}
        ''

        # p10k's own convention is to source ~/.p10k.zsh last, after the theme
        # and the rest of .zshrc have loaded.
        (lib.mkAfter ''
          [ -f "$HOME/.p10k.zsh" ] && source "$HOME/.p10k.zsh"
        '')
      ];
    };
  };
}
