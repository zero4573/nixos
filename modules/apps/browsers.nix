_: {
  # Brave (default) + Chromium (alternative).
  flake.nixosModules.browsers = { pkgs, ... }: {
    environment.systemPackages = with pkgs; [
      brave
      chromium
    ];
  };

  flake.homeModules.browsers = _: {
    # Brave as the default browser for http(s)/html.
    xdg.mimeApps = {
      enable = true;
      defaultApplications = {
        "x-scheme-handler/http" = "brave-browser.desktop";
        "x-scheme-handler/https" = "brave-browser.desktop";
        "text/html" = "brave-browser.desktop";
      };
    };
  };
}
