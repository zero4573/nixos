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

    # Disable IPv6, as certain apps like intune will fail otherwise
    networking.enableIPv6 = false;

    # Overrides ipv6 address resolution precendence so that ipv4 are
    # prefered
    networking.getaddrinfo.precedence = {
      "::ffff:0:0/96" = 100;
      "::1/128" = 50;
      "::/0" = 40;
    };

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
      jq

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

    # Kill cgroups under memory pressure instead of letting the whole system
    # freeze (e.g. IntelliJ + Docker + browser all running at once) --
    # trade-off: a runaway process (mid-indexing, say) can get killed
    # abruptly with no prompt. `enable` already defaults to true.
    systemd.oomd = {
      enableRootSlice = true;
      enableUserSlices = true;
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
