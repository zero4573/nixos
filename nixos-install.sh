#!/bin/bash

set -euo pipefail

host="${1}"

sudo nix --extra-experimental-features 'nix-command flakes' run github:nix-community/disko -- --mode disko --flake ".#${host}"
sudo nixos-install --flake ".#${host}" --root /mnt
