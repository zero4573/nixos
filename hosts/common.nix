{ self, ... }: {
  flake.nixosModules.commonConfigs = { pkgs, config, lib, ... }:
  let
    cfg = config.hostConfig;
  in {
    imports = [
      self.nixosModules.hostOptions
      self.nixosModules.users
    ];

    networking.hostName = cfg.hostName;

    system.stateVersion = cfg.stateVersion;

    # Set your time zone.
    time.timeZone = cfg.timezone;

    # Select internationalisation properties.
    i18n.defaultLocale = cfg.defaultLocale;

    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    # Keep the store bounded.
    nix.settings.auto-optimise-store = true;
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };

    nixpkgs.config.allowUnfree = true;

    environment.systemPackages = with pkgs; [
      git
      btop
      lazygit
      yt-dlp
      zip
      # chattr/lsattr -- otherwise only pulled in as an internal dependency
      # of modules/home/nodatacow.nix, not on the interactive PATH.
      e2fsprogs
    ];

    programs.neovim = {
      enable = true;
      defaultEditor = true;
    };


    programs.git = {
      enable = true;
      config = {
        pull.rebase = true;
        push.autoSetupRemote = true;
      } // lib.optionalAttrs (cfg.git.userName != "" && cfg.git.userEmail != "") {
        user = {
          name = cfg.git.userName;
          email = cfg.git.userEmail;
        };
      };
    };

    # Passwordless sudo for the primary user, on every host.
    security.sudo.extraRules = [{
      users = [ cfg.user.name ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }];
  };
}
