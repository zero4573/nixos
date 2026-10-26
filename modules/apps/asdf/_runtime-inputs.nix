# Tools on the asdf-gcroots unit's PATH besides nix (not a flake-parts module:
# the leading underscore keeps import-tree off it). Shared by the module and
# the flake check, which runs the script with exactly these on PATH.
pkgs: [ pkgs.gnugrep pkgs.findutils pkgs.coreutils ]
