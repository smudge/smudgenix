# smx: the smudgenix command. (Packaged by ./smx.nix, which sets $system.)

system_flake=/etc/nixos
home_flake="$HOME/.config/home-manager"
devshells="${SMX_DEVSHELLS:-$HOME/.config/devshells}"

tildify() { case "$1" in "$HOME"/*) echo "~${1#"$HOME"}" ;; *) echo "$1" ;; esac; }

usage() {
  cat <<EOF
Usage: smx <command> [args]

Commands:
  upgrade [args]       Update and switch to this machine's flake, /etc/nixos
                       (with sudo). Args go to nixos-rebuild.
  home update [args]   Update and switch to your home flake,
                       ~/.config/home-manager. Args go to nix build.
  direnv <shell> [-f]  Write a .envrc using a devShell from $(tildify "$devshells")
  direnv               List the available shells
  help                 Show this help
EOF
}

# Use the gh login (if any) for GitHub API access, avoiding rate limits.
github_token() {
  if command -v gh >/dev/null && token=$(gh auth token 2>/dev/null); then
    export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG
}access-tokens = github.com=$token"
  fi
}

# Regenerate the flake's lock from scratch, picking up everything upstream.
relock() {
  rm -f "$1/flake.lock"
  nix flake update --flake "$1"
}

upgrade() {
  if [ "$(id -u)" -ne 0 ]; then
    github_token
    exec sudo --preserve-env=NIX_CONFIG "$0" upgrade "$@"
  fi
  relock "$system_flake"
  nixos-rebuild switch --flake "$system_flake" "$@"
}

home_update() {
  github_token
  relock "$home_flake"
  out=$(nix build --no-link --print-out-paths "$@" \
    "$home_flake#homeConfigurations.\"$USER\".activationPackage")
  HOME_MANAGER_BACKUP_EXT=hm-bak "$out/activate"
}

list_shells() {
  nix eval --json "$devshells#devShells.$system" --apply builtins.attrNames | jq -r '.[]'
}

direnv_shell() {
  shell="${1:-}"
  if [ -z "$shell" ]; then
    echo "Available shells in $devshells:"
    list_shells | sed 's/^/  /'
    return
  fi
  if ! list_shells | grep -qx "$shell"; then
    echo "smx: no devShell '$shell' in $devshells" >&2
    echo "Available: $(list_shells | tr '\n' ' ')" >&2
    exit 1
  fi
  if [ -e .envrc ] && [ "${2:-}" != "-f" ]; then
    echo "smx: .envrc already exists (use -f to overwrite):" >&2
    sed 's/^/  /' .envrc >&2
    exit 1
  fi
  echo "use flake $devshells#$shell" > .envrc
  direnv allow .
  echo "smx: wrote .envrc -> $shell"
}

case "${1:-help}" in
  upgrade) shift; upgrade "$@" ;;
  home)
    case "${2:-}" in
      update) shift 2; home_update "$@" ;;
      *) echo "smx: usage: smx home update [args]" >&2; exit 1 ;;
    esac
    ;;
  direnv) shift; direnv_shell "$@" ;;
  help|-h|--help) usage ;;
  *) echo "smx: unknown command '$1'" >&2; usage >&2; exit 1 ;;
esac
