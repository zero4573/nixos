_: {
  flake.nixosModules.commonConfigs = { pkgs, ... }: {
    system.stateVersion = "26.11";

    # Set your time zone.
    time.timeZone = "America/Toronto";

    # Select internationalisation properties.
    i18n.defaultLocale = "en_CA.UTF-8";

    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    environment.systemPackages = with pkgs; [
      vim
      git
      btop
      lazygit
    ];

    programs.vim = {
      enable = true;
      defaultEditor = true;
    };

    programs.git = {
      enable = true;
      config = {
        pull.rebase = true;
        push.autoSetupRemote = true;
      };
    };
  };
}