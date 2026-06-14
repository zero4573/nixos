#!/bin/bash

set -euo pipefail

host="${1}"

base_dir=$(readlink -f "$(dirname "${0}")")

sudo nixos-rebuild switch --flake "path:${base_dir}#${host}" --show-trace
# sudo nix-collect-garbage --delete-older-than 30d
# sudo nix-rebuild list-generations
