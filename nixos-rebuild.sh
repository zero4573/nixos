#!/bin/bash

set -euo pipefail

host="${1}"

base_dir=$(readlink -f "$(dirname "${0}")")

# nix ignores flake.nix's nixConfig substituters (vicinae's cachix) without --accept-flake-config
# --sudo: build as the user, whose ssh agent can fetch the private tix input; root only activates
nixos-rebuild switch --sudo --flake "path:${base_dir}#${host}" --show-trace --accept-flake-config
