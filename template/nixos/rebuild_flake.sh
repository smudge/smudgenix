#!/usr/bin/env bash
# Regenerate this host flake's lockfile from scratch, then rebuild & switch.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  if command -v gh >/dev/null && token=$(gh auth token 2>/dev/null); then
    export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG
}access-tokens = github.com=$token"
  fi
  exec sudo --preserve-env=NIX_CONFIG "$0" "$@"
fi

cd "$(dirname "$(readlink -f "$0")")"

rm -f flake.lock
nix --extra-experimental-features 'nix-command flakes' flake update --flake "$PWD"
nixos-rebuild switch --flake "$PWD" "$@"
