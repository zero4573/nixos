{ self, ... }: {
  flake.nixosModules.commonConfigs = { pkgs, config, lib, ... }:
  let
    cfg = config.hostConfig;
  in {
    imports = [
      self.nixosModules.hostOptions
      self.nixosModules.users
      self.nixosModules.mouseDebounce
      self.nixosModules.asdfGcroots
    ];

    networking.hostName = cfg.hostName;

    # intune fails with IPv6 enabled
    networking.enableIPv6 = false;

    networking.getaddrinfo.precedence = {
      "::ffff:0:0/96" = 100;
      "::1/128" = 50;
      "::/0" = 40;
    };

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

    time.timeZone = cfg.timezone;

    i18n.defaultLocale = cfg.defaultLocale;

    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    nix.settings.auto-optimise-store = true;
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };

    nixpkgs.config.allowUnfree = true;

    programs.nix-ld.enable = true;

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
      ripgrep
      tree
      gnumake
      bind
      gcc
      pkg-config
      autoconf
      automake
      m4

      e2fsprogs

      openssl
      unixodbc

      proton-drive-cli
    ];

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

        # kerl's configure finds OpenSSL/ODBC only through --with-ssl/--with-odbc=PATH holding include/ and lib/,
        # which Nix splits into separate outputs
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

    systemd.oomd = {
      enableRootSlice = true;
      enableUserSlices = true;
    };

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
