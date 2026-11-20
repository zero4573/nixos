{ self, ... }: {
  perSystem = { pkgs, ... }: {
    packages.review-broker = pkgs.buildGoModule {
      pname = "review-broker";
      version = "0.1.0";
      src = ./src;
      vendorHash = null;
      env.CGO_ENABLED = "0";
      meta.mainProgram = "review-broker";
    };
  };

  flake.homeModules.reviewBroker = { pkgs, lib, ... }: {
    options.programs.reviewBroker = {
      package = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.review-broker;
        defaultText = lib.literalExpression "self.packages.<system>.review-broker";
        description = "The review-broker package claude-sandbox runs.";
      };

      models = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching "[a-z0-9][a-z0-9.-]*");
        default = [ "gpt-5.6-sol" "glm-5" ];
        description = ''
          The kiro models (`kiro-cli chat --list-models`) a Claude session may
          ask for a deep review on, in order: each gets its own review file
          and finding numbers (100 for the first, 200 for the second, ...).
          Pick families Claude Code can't run. Empty: no broker.
        '';
      };

      effort = lib.mkOption {
        type = lib.types.str;
        default = "high";
        description = "kiro's --effort for a review.";
      };

      maxParallel = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2;
        description = "Reviews one session runs at once; more wait for a slot.";
      };

      timeout = lib.mkOption {
        type = lib.types.str;
        default = "45m";
        description = "A review's time limit (a Go duration); past it the run is stopped and reported as timeout.";
      };
    };
  };
}
