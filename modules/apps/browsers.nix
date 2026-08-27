_: {
  # Brave (default) + Chromium (alternative).
  flake.nixosModules.browsers = { pkgs, ... }: {
    environment.systemPackages = with pkgs; [
      brave
      chromium
    ];

    environment.sessionVariables.NIXOS_OZONE_WL = "1";

    environment.etc."brave/policies/managed/notifications.json".text = builtins.toJSON {
      AllowSystemNotifications = true;
    };
  };

  flake.homeModules.browsers = _: {
    # Default app associations: Brave for http(s)/html, Xournal++ for PDFs.
    xdg.mimeApps = {
      enable = true;
      defaultApplications = {
        "x-scheme-handler/http" = "brave-browser.desktop";
        "x-scheme-handler/https" = "brave-browser.desktop";
        "text/html" = "brave-browser.desktop";
        "application/pdf" = "com.github.xournalpp.xournalpp.desktop";
      };
    };
  };
}
