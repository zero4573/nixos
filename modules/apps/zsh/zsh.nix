_: {
  flake.nixosModules.zsh = { pkgs, config, ... }: {
    programs.zsh.enable = true;
    users.users.${config.hostConfig.user.name}.shell = pkgs.zsh;
  };

  flake.homeModules.zsh = { pkgs, lib, asdfPlugins, asdfVersions, ... }: {
    home.packages = [ pkgs.asdf-vm ];

    home.activation.asdfPlugins = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      let
        asdf = lib.getExe pkgs.asdf-vm;
      in ''
        # the activation PATH has no git, which `asdf plugin add` clones with
        export PATH="${pkgs.git}/bin:$PATH"
      ''
      + lib.concatMapStringsSep "\n" (name: ''
        run ${asdf} plugin add ${lib.escapeShellArg name} || true
      '') asdfPlugins
    );

    # a user service, not activation: a download like Flutter's SDK can outlast home-manager's 5 min activation timeout
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

    programs.fzf = {
      enable = true;
      enableZshIntegration = true;
    };
    programs.zoxide = {
      enable = true;
      enableZshIntegration = true;
    };

    home.file.".alias".text = ''

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
        # powerlevel10k's instant prompt needs the theme loaded before anything prints
        (lib.mkBefore ''
          source "${pkgs.zsh-powerlevel10k}/share/zsh-powerlevel10k/powerlevel10k.zsh-theme"
        '')
        ''
          # zsh picks the vi keymap when $EDITOR contains vi
          bindkey -e

          # Alacritty's xterm-style Alt/Ctrl+Left/Right sequences aren't in zsh's default emacs keymap
          bindkey '^[[1;3D' backward-word
          bindkey '^[[1;3C' forward-word
          bindkey '^[[1;5D' backward-word
          bindkey '^[[1;5C' forward-word

          source "${pkgs.asdf-vm}/etc/profile.d/asdf-prepare.sh"
          [ -f "$HOME/.alias" ] && source "$HOME/.alias"
          [ -f "$HOME/.custom" ] && source "$HOME/.custom"

          source ${./cmd-timing.zsh}
        ''

        # p10k's convention: source ~/.p10k.zsh last
        (lib.mkAfter ''
          [ -f "$HOME/.p10k.zsh" ] && source "$HOME/.p10k.zsh"
        '')
      ];
    };
  };
}
