{ self, ... }: {
  flake.nixosModules.commonConfigs = { pkgs, config, lib, ... }:
  let
    cfg = config.hostConfig;
  in {
    imports = [
      self.nixosModules.hostOptions
      self.nixosModules.users
      self.nixosModules.mouseDebounce
    ];

    nixpkgs.overlays = [
      (final: prev: {
        proton-drive-cli = final.callPackage ../pkgs/proton-drive-cli { };

        # Upstream asdf-vm 0.20.1 git tag was deleted after the fact
        # (nixpkgs still points at it), so the fixed-output source fetch
        # 404s. Pin to 0.20.2 until nixpkgs catches up; vendorHash is
        # unchanged from 0.20.1 (go.mod/go.sum didn't move between patches).
        asdf-vm = prev.asdf-vm.overrideAttrs (old: {
          version = "0.20.2";
          src = final.fetchFromGitHub {
            owner = "asdf-vm";
            repo = "asdf";
            tag = "v0.20.2";
            hash = "sha256-HJRNRA98MIOEF/Q3I+cGUL8kH904j3/msI+FGDbRH7A=";
          };
          vendorHash = "sha256-ompvvNzfJetcKCRueJxXALiN0rOQwSiytTHJcVXFEOo=";
        });

        # xwayland-satellite 0.8.2 regressed override-redirect popups: Steam's
        # context/dropdown menus open and dismiss instantly under niri
        # (Supreeeme/xwayland-satellite#468, #503). Pin to 0.8.1 until a
        # release with the fix lands in nixpkgs.
        xwayland-satellite = prev.xwayland-satellite.overrideAttrs (finalAttrs: old: {
          version = "0.8.1";
          src = final.fetchFromGitHub {
            owner = "Supreeeme";
            repo = "xwayland-satellite";
            tag = "v0.8.1";
            hash = "sha256-BUE41HjLIGPjq3U8VXPjf8asH8GaMI7FYdgrIHKFMXA=";
          };
          cargoDeps = final.rustPlatform.fetchCargoVendor {
            inherit (finalAttrs) pname version src;
            hash = "sha256-16L6gsvze+m7XCJlOA1lsPNELE3D364ef2FTdkh0rVY=";
          };
        });
      })
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

    # Allow for custom /etc/hosts management
    environment.etc.hosts.enable = false;
    system.activationScripts.etcHostsBaseline = ''
      if [ ! -e /etc/hosts ]; then
        {
          echo "127.0.0.1 localhost"
          echo ""
          echo "127.0.0.2 ${cfg.hostName}"
        } > /etc/hosts
      fi
    '';

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

    # Lets prebuilt, dynamically-linked generic-Linux binaries run as-is (go)
    # NixOS has no FHS paths for the loader/libs they expect, so this provides one.
    programs.nix-ld.enable = true;

    # Extra libs beyond nix-ld's default set
    programs.nix-ld.libraries = with pkgs; [
      libxinerama
      libx11
      libxext
      libxcb
      libxcb-util
      libsm
      libice
      libglvnd
      libxkbcommon
      keyutils
      util-linux
      zstd
      fontconfig
      freetype
      dbus
      systemd
    ];

    environment.systemPackages = with pkgs; [
      git
      git-lfs
      btop
      lazygit
      yt-dlp
      zip
      unzip
      jq
      gnumake
      bind
      gcc
      pkg-config
      autoconf
      automake
      m4

      # chattr/lsattr -- otherwise only pulled in as an internal dependency
      # of modules/home/nodatacow.nix, not on the interactive PATH.
      e2fsprogs

      # openssl/odbcinst/isql CLIs, for interactive use.
      openssl
      unixodbc

      proton-drive-cli
    ];

    # Add build dependencies
    environment.sessionVariables =
      let
        buildFromSourceDeps = with pkgs; [
          zlib
          openssl
          bzip2
          readline
          sqlite
          ncurses
          libffi
          xz
          gdbm
          libuuid
          expat
          libxcrypt
          unixodbc
        ];

        # kerl/erlang's ./configure (lib/crypto, lib/odbc) doesn't use
        # pkg-config or CPATH/LIBRARY_PATH to find OpenSSL/ODBC, it uses
        # --with-ssl=PATH / --with-odbc=PATH that must contain both
        # PATH/include and PATH/lib under one root. Nix splits those into
        # separate dev/lib outputs, so build merged trees to point at
        mergeIncludeLib = name: pkg: pkgs.runCommand "${name}-merged" { } ''
          mkdir -p $out
          ln -s ${lib.getLib pkg}/lib $out/lib
          ln -s ${lib.getDev pkg}/include $out/include
        '';
        opensslMerged = mergeIncludeLib "openssl" pkgs.openssl;
        unixodbcMerged = mergeIncludeLib "unixodbc" pkgs.unixodbc;
      in
      {
        CPATH = lib.makeSearchPathOutput "dev" "include" buildFromSourceDeps;
        LIBRARY_PATH = lib.makeLibraryPath buildFromSourceDeps;
        PKG_CONFIG_PATH = lib.makeSearchPathOutput "dev" "lib/pkgconfig" buildFromSourceDeps;
        KERL_CONFIGURE_OPTIONS = "--with-ssl=${opensslMerged} --with-odbc=${unixodbcMerged}";
      };

    programs.neovim = {
      enable = true;
      defaultEditor = true;
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
