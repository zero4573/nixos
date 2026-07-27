_: {
  flake.nixosModules.intune = { ... }: {
    nixpkgs.overlays = [
      (final: prev: {
        microsoft-identity-broker = prev.microsoft-identity-broker.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.makeWrapper ];
          postFixup = (old.postFixup or "") + ''
            wrapProgram $out/bin/microsoft-identity-broker \
              --set WEBKIT_DISABLE_DMABUF_RENDERER 1 \
              --set WEBKIT_DISABLE_COMPOSITING_MODE 1 \
              --set GDK_BACKEND x11
          '';
        });

        intune-portal = prev.intune-portal.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.makeWrapper ];
          postFixup = (old.postFixup or "") + ''
            wrapProgram $out/bin/intune-portal \
              --set WEBKIT_DISABLE_DMABUF_RENDERER 1 \
              --set WEBKIT_DISABLE_COMPOSITING_MODE 1 \
              --set GDK_BACKEND x11
          '';
        });
      })
    ];

    services.intune.enable = true;

    systemd.sockets.intune-daemon.wantedBy = [ "sockets.target" ];
    systemd.user.timers.intune-agent.wantedBy = [ "graphical-session.target" ];
  };
}
