_: {
  flake.nixosModules.teamviewer = { pkgs, ... }: let
    # patchelf >= 0.18 rewrites teamviewerd with an RW LOAD segment that
    # overlaps the code segment's first page, so it segfaults in ld.so before
    # main(). 0.15.2 (stdenv's patchelf until the Oct 2026 nixpkgs bump) works.
    # Drop this once a newer patchelf produces a teamviewerd that starts.
    patchelf_0_15 = pkgs.patchelf.overrideAttrs {
      version = "0.15.2";
      src = pkgs.fetchurl {
        url = "https://github.com/NixOS/patchelf/releases/download/0.15.2/patchelf-0.15.2.tar.bz2";
        hash = "sha256-F3RfVkFZyOIo/EEtplogSLhGxLa0Igt3y/IkFuAvLXw=";
      };
    };
  in {
    services.teamviewer.enable = true;
    services.teamviewer.package = pkgs.teamviewer.overrideAttrs (old: {
      nativeBuildInputs = [ patchelf_0_15 ] ++ old.nativeBuildInputs;
    });
  };
}
