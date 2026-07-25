{ lib, ... }: {
  # flake.homeModules isn't a flake-parts-recognized output (unlike
  # flake.nixosModules), so multiple files each contributing a key under it
  # (e.g. desktop-home.nix's desktopHome, noctalia.nix's noctalia) would
  # conflict without this option declaration.
  options.flake.homeModules = lib.mkOption {
    type = lib.types.lazyAttrsOf lib.types.deferredModule;
    default = { };
    description = "Home-manager modules exposed by this flake, analogous to flake.nixosModules.";
  };

  # Custom, host-configurable settings namespace. Hosts SET these values (see
  # each host's settings.nix); shared modules (commonConfigs, users, etc.) READ
  # them via config.hostConfig.*.
  config.flake.nixosModules.hostOptions = { lib, ... }: {
    # nixpkgs' own programs.niri module has no settings/binds option -- this
    # is our own extension point so other modules (onepassword, workProfile,
    # ...) can each contribute niri binds without modules/niri/niri.nix
    # needing to know about them. Values are bind-name -> bind-value (either
    # the simple `{ action = arg; }` form or the `_: { props = ...; content =
    # ...; }` form niri's wrapper-modules settings accept), left unrestricted
    # since niri's own `niri validate` (run at build time by the wrapper)
    # catches mistakes.
    options.programs.niri.extraBinds = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Extra niri keybinds merged into the generated config.";
    };

    # Same extension-point pattern as programs.niri.extraBinds above: profiles
    # append to this list (desktopProfile sets the shared base, workProfile
    # adds more), and modules/apps/zsh.nix's home-manager module (which
    # receives it via extraSpecialArgs, see modules/home/home-manager.nix)
    # installs each as an asdf plugin on activation.
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

        # NixOS's own docs note this is world-readable in the Nix store, so
        # it's only for bootstrapping a fresh install -- change it via
        # `passwd` right after first login (mutableUsers, NixOS's default,
        # means later passwd changes aren't clobbered by rebuilds).
        initialPassword = lib.mkOption {
          type = lib.types.str;
          default = "password";
          description = "Initial (world-readable, change-immediately) password for the primary user.";
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
      };

      profile = lib.mkOption {
        type = lib.types.enum [ "work" "personal" ];
        default = "work";
        description = "Coarse host profile; gates work-only autostart etc.";
      };
    };
  };
}
