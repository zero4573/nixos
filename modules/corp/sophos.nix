_: {
  # Sophos SPL can't be packaged: its installer is tenant-specific (carries registration tokens) and the agent
  # downloads and updates its own binaries in /opt/sophos-spl, so the install is imperative.
  flake.nixosModules.sophos = { config, pkgs, ... }:
    let
      installDir = "/opt/sophos-spl";
      installerDir = "/var/lib/sophos-spl-installer";
      installer = "${installerDir}/SophosSetup.sh";
      installedMarker = "${installerDir}/installed";

      # what SophosSetup.sh's verify_necessary_commands and pre-install checks call
      tools = with pkgs; [
        bash
        coreutils
        curl
        diffutils
        findutils
        gawk
        getent # separate from glibc.bin in nixpkgs
        glibc.bin # ldd
        gnugrep
        gnused
        gnutar
        gzip
        hostname
        openssl
        procps
        shadow
        systemd
        util-linux
        which
      ];

      sophosInstall = pkgs.writeShellApplication {
        name = "sophos-install";
        runtimeInputs = tools;
        text = ''
          if [[ $# -lt 1 || ! -f $1 ]]; then
            echo "usage: sudo sophos-install /path/to/SophosSetup.sh [installer options]" >&2
            exit 64
          fi
          if [[ $EUID -ne 0 ]]; then
            echo "sophos-install: run as root (sudo)" >&2
            exit 1
          fi
          installer=$1
          shift
          # the installer takes our always-present sophos-spl.service to mean SPL is installed and fails
          # (exit 20) until a first install completes; --force would skip re-registration afterwards
          if [[ ! -e ${installedMarker} ]]; then
            set -- --force "$@"
          fi
          bash "$installer" "$@"
          mkdir -p ${installerDir}
          touch ${installedMarker}
        '';
      };
    in
    {
      programs.nix-ld.libraries = [ pkgs.libcap ];

      services.envfs.enable = true;

      environment.systemPackages = [ sophosInstall ];

      # SPL's installer needs a unit directory to write into (NixOS doesn't load it), and SulDownloader
      # looks for systemctl only in /usr/bin, /usr/local/bin and /usr/sbin, not PATH
      systemd.tmpfiles.rules = [
        "d /usr/lib/systemd/system 0755 root root -"
        "d ${installerDir} 0700 root root -"
        "L+ /usr/sbin/systemctl - - - - ${config.systemd.package}/bin/systemctl"
      ] ++ map (tool: "L+ /usr/sbin/${tool} - - - - ${pkgs.shadow}/bin/${tool}") [
        "useradd"
        "usermod"
        "userdel"
        "groupadd"
        "groupmod"
        "groupdel"
      ];

      # Not ordered against sophos-spl: the installer runs `systemctl start sophos-spl` itself (deadlock).
      # Type=exec so a switch doesn't wait for the download or fail with the install.
      systemd.services.sophos-spl-install = {
        description = "Install Sophos Protection for Linux";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        unitConfig = {
          ConditionPathExists = [
            installer
            "!${installedMarker}"
          ];
        };
        restartIfChanged = false;
        serviceConfig = {
          Type = "exec";
          # on failure the installer writes sophos_diagnose.tgz to its working directory
          WorkingDirectory = installerDir;
          ExecStart = "${sophosInstall}/bin/sophos-install ${installer}";
          TimeoutStartSec = "30min";
        };
      };

      systemd.slices.sophos = {
        description = "Sophos Protection for Linux";
      };

      systemd.services.sophos-spl = {
        description = "Sophos Linux Protection";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        path = tools;
        environment.SOPHOS_INSTALL = installDir;
        unitConfig = {
          ConditionPathExists = "${installDir}/base/bin/sophos_watchdog";
          DefaultDependencies = false;
          StartLimitIntervalSec = 0;
        };
        serviceConfig = {
          ExecStart = "${installDir}/base/bin/sophos_watchdog";
          Restart = "always";
          KillMode = "mixed";
          Delegate = true;
          # SPL applies its CPU/memory limits under sophos.slice/sophos-spl.service
          Slice = "sophos.slice";
          LimitCORE = 0;
        };
        # SPL updates its own files in /opt
        restartIfChanged = false;
      };
    };
}
