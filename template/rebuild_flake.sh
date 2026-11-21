#!/usr/bin/env bash
# Regenerate this host flake's lockfile from scratch, then rebuild & switch.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"

cd "$(dirname "$(readlink -f "$0")")"

rm -f flake.lock
nix --extra-experimental-features 'nix-command flakes' flake update --flake "$PWD"
nixos-rebuild switch --flake "$PWD" "$@"
