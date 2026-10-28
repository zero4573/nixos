{ self, ... }: {
  # git-ssh-broker: git over SSH, and commit signing, for claude-sandbox
  # without an SSH key or the host's ssh-agent in the sandbox. Hand-written
  # (./src, standard library only) so every line that stands between a
  # sandbox and your 1Password SSH keys is auditable.
  #
  # claude-sandbox.sh starts one per session, on the host, and mounts its two
  # sockets in:
  #  * git: the sandbox's GIT_SSH_COMMAND is `git-ssh-broker client`. Only
  #    git's transport commands (fetch, push, archive) to git@ on the allowed
  #    hosts (GitHub and Bitbucket Cloud, every repo) are run, with the host's
  #    own ssh (~/.ssh/config, the 1Password agent): no shell, no options or
  #    forwarding from the sandbox. A push is checked before anything reaches
  #    the remote: deleting a branch or tag, moving a tag, and any
  #    non-fast-forward update (a force push, --force-with-lease, +refspec)
  #    are refused for the whole push. Those stay manual steps on the host.
  #    The fast-forward check reads only the object store of the client's
  #    repo, through a throwaway git dir, so the sandbox's repo config, hooks,
  #    replace refs and grafts never run or count on the host.
  #  * agent: the sandbox's SSH_AUTH_SOCK, an ssh-agent filter in front of
  #    the host's that lists only the signing keys (signingKeys below) and
  #    signs only git signatures (SSHSIG, namespace "git"); SSH logins and
  #    every other agent request are refused. Sessions commit signed.
  # Anything running in a sandbox can push (non-force) to any repo your keys
  # reach and sign commits as you; 1Password still asks to approve the
  # broker's use of the keys. Its log goes to ~/.local/state/claude-sandbox.log.
  #
  #   nix build .#git-ssh-broker   (runs its tests)
  perSystem = { pkgs, ... }: {
    packages.git-ssh-broker = pkgs.buildGoModule {
      pname = "git-ssh-broker";
      version = "0.1.0";
      src = ./src;
      vendorHash = null;
      # The tests push through the broker with real git and sign through a
      # real ssh-agent
      nativeCheckInputs = [ pkgs.git pkgs.openssh ];
      meta.mainProgram = "git-ssh-broker";
    };
  };

  flake.homeModules.gitSshBroker = { pkgs, lib, config, osConfig, ... }: {
    options.programs.gitSshBroker = {
      package = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.git-ssh-broker;
        defaultText = lib.literalExpression "self.packages.<system>.git-ssh-broker";
        description = "The git-ssh-broker package claude-sandbox runs.";
      };

      signingKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = lib.pipe osConfig.hostConfig.git.identities [
          (map (i: i.signingKey))
          (lib.filter (k: k != ""))
          lib.unique
        ];
        defaultText = lib.literalExpression "the signingKey of each hostConfig.git.identities entry";
        description = ''
          OpenSSH public key files the sandbox may sign git signatures with
          (their private halves stay in the host's agent). A missing file is
          skipped at launch.
        '';
      };

      upstreamAgent = lib.mkOption {
        type = lib.types.str;
        default = "${config.home.homeDirectory}/.1password/agent.sock";
        defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/.1password/agent.sock"'';
        description = ''
          The host's ssh-agent socket the signing filter forwards to, when the
          launching shell has no SSH_AUTH_SOCK.
        '';
      };
    };
  };
}
