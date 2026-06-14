#!/bin/bash

host="${1}"

sudo nixos-rebuild switch --flake ".#${host}" --show-trace
