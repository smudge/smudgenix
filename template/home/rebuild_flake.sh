#!/usr/bin/env bash
# Regenerate this home flake's lockfile from scratch, then switch.
set -euo pipefail

if command -v gh >/dev/null && token=$(gh auth token 2>/dev/null); then
  export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG
}access-tokens = github.com=$token"
fi

cd "$(dirname "$(readlink -f "$0")")"

rm -f flake.lock
nix flake update
home-manager switch -b hm-bak "$@"
