{ self, ... }: {
  perSystem = { pkgs, ... }: {
    packages.git-ssh-broker = pkgs.buildGoModule {
      pname = "git-ssh-broker";
      version = "0.1.0";
      src = ./src;
      vendorHash = null;
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

      rewritableBranches = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "feature/*" ];
        description = ''
          Branch name globs (Go path.Match: `*` and `?` don't cross a `/`,
          so "feature/*" is feature/x but not feature/x/y) a push from the
          sandbox may rewrite, when every commit it drops is yours (see
          identityEmails). Empty: no rewrite.
        '';
      };

      identityEmails = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = lib.pipe ([ osConfig.hostConfig.git.userEmail ]
          ++ map (i: i.userEmail) osConfig.hostConfig.git.identities) [
          (lib.filter (e: e != ""))
          lib.unique
        ];
        defaultText = lib.literalExpression
          "hostConfig.git.userEmail and the userEmail of each hostConfig.git.identities entry";
        description = ''
          Your git emails: a rewrite of a rewritableBranches branch may drop
          only commits whose author and committer emails are both in this
          list (case-insensitive). Empty: no rewrite is ever allowed.
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
