{ lib, ... }: {
  options.flake.homeModules = lib.mkOption {
    type = lib.types.lazyAttrsOf lib.types.deferredModule;
    default = { };
    description = "Home-manager modules exposed by this flake, analogous to flake.nixosModules.";
  };

  config.flake.nixosModules.hostOptions = { lib, ... }: {
    options.programs.niri.extraBinds = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Extra niri keybinds merged into the generated config.";
    };

    options.programs.asdf.plugins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "asdf plugin names to install for the primary user.";
    };

    options.hostConfig = {
      user = {
        name = lib.mkOption {
          type = lib.types.str;
          description = "Primary user account name.";
        };
        description = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Primary user GECOS/description.";
        };
        extraGroups = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "networkmanager" "wheel" ];
          description = "Extra groups for the primary user.";
        };

        initialPassword = lib.mkOption {
          type = lib.types.str;
          default = "password";
          description = "Initial user password, CHANGE IMMEDIATELY AFTER LOGGIN via `sudo passwd <username>`";
        };
      };

      hostName = lib.mkOption {
        type = lib.types.str;
        description = "System hostname (networking.hostName).";
      };

      stateVersion = lib.mkOption {
        type = lib.types.str;
        default = "26.11";
        description = "NixOS system.stateVersion.";
      };

      timezone = lib.mkOption {
        type = lib.types.str;
        default = "America/Toronto";
        description = "System time zone.";
      };

      defaultLocale = lib.mkOption {
        type = lib.types.str;
        default = "en_CA.UTF-8";
        description = "Default i18n locale.";
      };

      git = {
        userName = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Default git user.name.";
        };
        userEmail = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Default git user.email.";
        };

        # Per-remote identity/signing overrides, applied via git conditional
        # includes -- see modules/apps/git.nix.  An entry with only
        # `condition` set (no userName/userEmail/signingKey) is dropped
        # entirely rather than emitting an empty override.
        identities = lib.mkOption {
          type = lib.types.listOf (lib.types.submodule {
            options = {
              condition = lib.mkOption {
                type = lib.types.str;
                description = ''
                  git includeIf condition (see git-config(1)), e.g.
                  "hasconfig:remote.*.url:*github.com*/**". Note the
                  trailing "/**": a bare "*" doesn't cross a "/", so it
                  won't match SSH-style remotes (git@host:owner/repo.git).
                '';
              };
              userName = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = "git user.name for repos matching condition.";
              };
              userEmail = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = "git user.email for repos matching condition.";
              };
              signingKey = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = "SSH public key (or key path) for commits matching condition.";
              };
            };
          });
          default = [ ];
          description = "Per-remote git identity/signing overrides.";
        };
      };

      profile = lib.mkOption {
        type = lib.types.enum [ "work" "personal" ];
        default = "work";
        description = "Coarse host profile; gates work-only autostart etc.";
      };
    };
  };
}
