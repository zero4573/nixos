#!/bin/bash

set -euo pipefail

host="${1}"

base_dir=$(readlink -f "$(dirname "${0}")")

# --accept-flake-config trusts the vicinae cachix substituter declared in
# flake.nix (avoids rebuilding vicinae/Qt from source).
sudo nixos-rebuild switch --flake "path:${base_dir}#${host}" --show-trace --accept-flake-config

# sudo nix-collect-garbage --delete-older-than 30d
# sudo nix-rebuild list-generations
