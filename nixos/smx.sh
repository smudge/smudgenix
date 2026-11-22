# smx: the smudgenix command. (Packaged by ./smx.nix, which sets $system.)
#
# `smx …` works on your home (~/.config/home-manager), and never needs root.
# `smx os …` works on the OS (/etc/nixos), shared by every user, and asks for
# sudo only to change it.

home_flake="$HOME/.config/home-manager"
home_profile="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager"
home_state="${XDG_STATE_HOME:-$HOME/.local/state}/smudgenix"
os_flake=/etc/nixos
os_profile=/nix/var/nix/profiles/system
os_state=/var/lib/smudgenix
devshells="${SMX_DEVSHELLS:-$HOME/.config/devshells}"

args=("$@")

say() { echo "smx: $*" >&2; }
die() { say "$*"; exit 1; }

tildify() { case "$1" in "$HOME"/*) echo "~${1#"$HOME"}" ;; *) echo "$1" ;; esac; }

usage() {
  cat <<EOF
Usage: smx <command> [args]

Your home ($(tildify "$home_flake")):
  status                  Show your home's status
  update                  Get the latest, and apply it
  config apply            Apply your config's changes (without updating);
                          --local <checkout> uses that smudgenix instead
  history                 List your home's generations
  revert [<gen>]          Go back to the previous generation, or to <gen>

The OS (/etc/nixos), shared by every user:
  os ...                  The same commands, for the OS (see \`smx os help\`)

Tools:
  env [<shell> [-f]]      Write a .envrc using a devShell from $(tildify "$devshells"),
                          or list them
  help                    Show this help
EOF
}

os_usage() {
  cat <<EOF
Usage: smx os <command> [args]

The OS (/etc/nixos), shared by every user. Changing it takes sudo.

  status                  Show the OS's status
  update [when]           Get the latest, and apply it
  config apply [when]     Apply the config's changes (without updating);
                          --local <checkout> uses that smudgenix instead
  history                 List the OS's generations
  revert [<gen>] [when]   Go back to the previous generation, or to <gen>
  upgrade                 Move to the next smudgenix release

[when] is when it takes effect: now and for good (by default), or
  --try                   now, until the next reboot
  --on-reboot             at the next reboot, and for good
EOF
}

# --- Shared helpers -------------------------------------------------------

# Use the gh login (if any) for GitHub API access, avoiding rate limits.
github_token() {
  if command -v gh >/dev/null && token=$(gh auth token 2>/dev/null); then
    export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG
}access-tokens = github.com=$token"
  fi
}

# Regenerate a flake's lock from scratch, picking up everything upstream.
relock() {
  rm -f "$1/flake.lock"
  nix flake update --flake "$1"
}

# Splits the args into $when (switch/test/boot), $checkout and $extra.
parse_apply_args() {
  when=switch checkout="" extra=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --try) when="test" ;;
      --on-reboot) when="boot" ;;
      --local)
        [ $# -ge 2 ] || die "--local takes a path to a smudgenix checkout"
        checkout=$(realpath "$2") || die "no such checkout: $2"
        shift ;;
      *) extra+=("$1") ;;
    esac
    shift
  done
}

# When a generation (or profile) link was made, not its store path's 1970.
link_date() { date -d "@$(stat -c %Y "$1")" '+%Y-%m-%d %H:%M'; }

# A profile's generations, as "<number> <store path> <date>", oldest first.
generations() {
  for link in "$1"-*-link; do
    [ -e "$link" ] || continue
    n=${link##"$1"-}; n=${n%-link}
    printf '%s %s %s\n' "$n" "$(readlink -f "$link")" "$(link_date "$link")"
  done | sort -n
}

current_generation() { readlink "$1" | sed -E 's/.*-([0-9]+)-link$/\1/'; }

# The store path of generation $2 of profile $1, or by default the latest
# one before the current that differs from it.
generation_path() {
  if [ -n "${2:-}" ]; then
    [[ "$2" =~ ^[0-9]+$ ]] || die "not a generation number: $2"
    [ -e "$1-$2-link" ] || die "no generation $2 (see the history)"
    readlink -f "$1-$2-link"
    return
  fi
  current=$(readlink -f "$1")
  path=$(generations "$1" | awk -v c="$(current_generation "$1")" -v p="$current" \
    '$1 < c && $2 != p { last = $2 } END { print last }')
  [ -n "$path" ] || die "there's no earlier generation to go back to"
  echo "$path"
}

# A profile's generations, newest last, noting the current one and copies
# of earlier ones (made by reverting). For the OS ($2 = os), with the NixOS
# version and the booted one.
history_of() {
  current=$(current_generation "$1")
  booted=$(readlink -f /run/booted-system)
  declare -A first=()
  generations "$1" | while read -r n path day time; do
    notes=""
    note() { notes="${notes:+$notes, }$1"; }
    [ "$n" != "$current" ] || note current
    [ "${2:-}" != os ] || [ "$path" != "$booted" ] || note booted
    if [ -n "${first[$path]:-}" ]; then note "same as ${first[$path]}"; else first[$path]=$n; fi
    version=""
    [ "${2:-}" != os ] || version="  NixOS $(cat "$path/nixos-version" 2>/dev/null)"
    printf '%5s  %s %s%s%s\n' "$n" "$day" "$time" "$version" "${notes:+  ($notes)}"
  done
}

generation_number() { generations "$1" | awk -v p="$2" '$2 == p { n = $1 } END { print n }'; }

# What smudgenix a lock file pins: "df2f7d5 (2026-11-21)", or a local path.
smudgenix_in() {
  [ -f "$1" ] || { echo "not locked yet"; return; }
  jq -r '.nodes.nixos.locked // empty
    | if .rev then "\(.rev[0:7]) (\(.lastModified | strftime("%Y-%m-%d")))"
      elif .path then "a local checkout, \(.path)" else "unknown" end' "$1"
}

smudgenix_rev() { jq -r '.nodes.nixos.locked | .rev // .narHash // ""' "$1" 2>/dev/null; }

# Whether the running OS needs a reboot to finish an update: a new kernel,
# initrd or kernel modules.
reboot_pending() {
  parts() { readlink "$1"/{initrd,kernel,kernel-modules}; }
  [ "$(parts /run/booted-system)" != "$(parts /run/current-system)" ]
}

# --- Your home ------------------------------------------------------------

home_lock() {
  mkdir -p "$home_state"
  exec 9>"${XDG_RUNTIME_DIR:-$home_state}/smx-home.lock"
  flock -n 9 || { say "waiting for another smx to finish with your home…"; flock 9; }
}

home_activate() {
  HOME_MANAGER_BACKUP_EXT=hm-bak "$1/activate"
}

home_apply() {
  parse_apply_args "$@"
  [ "$when" = switch ] || die "a home has no reboot to wait for, so takes no --try or --on-reboot"
  [ -f "$home_flake/flake.nix" ] || die "no home flake at $(tildify "$home_flake")"
  home_lock
  overrides=()
  [ -z "$checkout" ] || overrides=(--override-input system/nixos "path:$checkout")
  out=$(nix build --no-link --print-out-paths "${overrides[@]}" "${extra[@]}" \
    "$home_flake#homeConfigurations.\"$USER\".activationPackage")
  if [ -f "$home_state/home-reverted" ]; then
    say "leaving the revert to generation $(cat "$home_state/home-reverted")"
  fi
  home_activate "$out"
  rm -f "$home_state/home-reverted"
}

home_update() {
  [ -f "$home_flake/flake.nix" ] || die "no home flake at $(tildify "$home_flake")"
  github_token
  home_lock
  relock "$home_flake"
  home_apply "$@"
}

home_revert() {
  [ $# -le 1 ] || die "usage: smx revert [<gen>]"
  home_lock
  path=$(generation_path "$home_profile" "${1:-}")
  n=$(generation_number "$home_profile" "$path")
  home_activate "$path"
  echo "$n" > "$home_state/home-reverted"
  say "reverted to generation $n. Automatic updates wait until you next \`smx update\` or \`smx config apply\`."
}

home_history() { history_of "$home_profile"; }

home_status() {
  echo "Your home, $(tildify "$home_flake"):"
  if [ ! -e "$home_profile" ]; then
    echo "  not applied yet"
  else
    n=$(current_generation "$home_profile")
    echo "  generation $n, applied $(link_date "$home_profile-$n-link")"
  fi
  echo "  smudgenix $(smudgenix_in "$home_flake/flake.lock")"
  if [ -f "$os_flake/flake.lock" ] && [ "$(smudgenix_rev "$home_flake/flake.lock")" != "$(smudgenix_rev "$os_flake/flake.lock")" ]; then
    echo "  The OS has another smudgenix, $(smudgenix_in "$os_flake/flake.lock"): \`smx update\` to catch up."
  fi
  if [ -f "$home_state/home-reverted" ]; then
    echo "  Reverted to generation $(cat "$home_state/home-reverted"); automatic updates wait until you next \`smx update\` or \`smx config apply\`."
  fi
  if reboot_pending; then
    echo "  The OS has an update waiting for a reboot."
  fi
}

# --- The OS ---------------------------------------------------------------

# Re-run this command as root (it changes the OS). Only admins can.
as_root() {
  [ "$(id -u)" -ne 0 ] || return 0
  id -nG | tr ' ' '\n' | grep -qx wheel \
    || die "changing the OS takes an admin (a member of wheel); ask one to run \`smx ${args[*]}\`"
  github_token
  exec sudo --preserve-env=NIX_CONFIG "$0" "${args[@]}"
}

os_apply() {
  parse_apply_args "$@"
  as_root
  overrides=()
  [ -z "$checkout" ] || overrides=(--override-input nixos "path:$checkout")
  nixos-rebuild "$when" --flake "$os_flake" "${overrides[@]}" "${extra[@]}"
  [ "$when" = test ] || rm -f "$os_state/os-reverted"
}

os_update() {
  as_root
  relock "$os_flake"
  os_apply "$@"
}

os_revert() {
  gen="" when=switch
  for a in "$@"; do
    case "$a" in
      --try) when="test" ;;
      --on-reboot) when="boot" ;;
      *) [ -z "$gen" ] || die "usage: smx os revert [<gen>] [--try|--on-reboot]"; gen=$a ;;
    esac
  done
  path=$(generation_path "$os_profile" "$gen")
  n=$(generation_number "$os_profile" "$path")
  as_root
  if [ "$when" != test ]; then
    nix-env --profile "$os_profile" --set "$path"
  fi
  "$path/bin/switch-to-configuration" "$when"
  if [ "$when" != test ]; then
    mkdir -p "$os_state"
    echo "$n" > "$os_state/os-reverted"
    say "reverted to generation $n. Automatic updates wait until the next \`smx os update\` or \`smx os config apply\`."
  fi
}

os_history() { history_of "$os_profile" os; }

os_status() {
  echo "The OS, /etc/nixos ($(cat /proc/sys/kernel/hostname)):"
  n=$(current_generation "$os_profile")
  echo "  generation $n, applied $(link_date "$os_profile-$n-link"), NixOS $(cat /run/current-system/nixos-version)"
  echo "  smudgenix $(smudgenix_in "$os_flake/flake.lock")"
  if reboot_pending; then
    echo "  An update is waiting for a reboot (a new kernel or drivers)."
  fi
  if [ -f "$os_state/os-reverted" ]; then
    echo "  Reverted to generation $(cat "$os_state/os-reverted"); automatic updates wait until the next \`smx os update\` or \`smx os config apply\`."
  fi
  last=$(systemctl show nixos-upgrade.service -p ExecMainExitTimestamp --value 2>/dev/null || true)
  if [ -n "$last" ] && [ "$last" != "n/a" ]; then
    result=$(systemctl show nixos-upgrade.service -p Result --value)
    echo "  Last automatic update: $last, $([ "$result" = success ] && echo "succeeded" || echo "failed (see \`journalctl -u nixos-upgrade\`)")"
  fi
  next=$(systemctl show nixos-upgrade.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)
  [ -z "$next" ] || [ "$next" = "n/a" ] || echo "  Next automatic update: $next"
}

os_upgrade() {
  echo "smudgenix has no releases to upgrade between yet: \`smx os update\` gets the latest."
}

# --- Tools ----------------------------------------------------------------

list_shells() {
  nix eval --json "$devshells#devShells.$system" --apply builtins.attrNames | jq -r '.[]'
}

env_shell() {
  shell="${1:-}"
  if [ -z "$shell" ]; then
    echo "Available shells in $(tildify "$devshells"):"
    list_shells | sed 's/^/  /'
    return
  fi
  if ! list_shells | grep -qx "$shell"; then
    say "no devShell '$shell' in $(tildify "$devshells")"
    die "available: $(list_shells | tr '\n' ' ')"
  fi
  if [ -e .envrc ] && [ "${2:-}" != "-f" ]; then
    say ".envrc already exists (use -f to overwrite):"
    sed 's/^/  /' .envrc >&2
    exit 1
  fi
  echo "use flake $devshells#$shell" > .envrc
  direnv allow .
  say "wrote .envrc -> $shell"
}

# --- Commands -------------------------------------------------------------

config_command() {
  scope=$1; shift
  case "${1:-}" in
    apply) shift; "${scope}_apply" "$@" ;;
    *) die "usage: smx $([ "$scope" = os ] && echo "os ")config apply" ;;
  esac
}

os_command() {
  case "${1:-}" in
    "") os_usage; echo; os_status ;;
    status) os_status ;;
    update) shift; os_update "$@" ;;
    config) shift; config_command os "$@" ;;
    history) os_history ;;
    revert) shift; os_revert "$@" ;;
    upgrade) os_upgrade ;;
    help|-h|--help) os_usage ;;
    *) say "unknown command 'os $1'"; os_usage >&2; exit 1 ;;
  esac
}

case "${1:-}" in
  "") usage; echo; home_status ;;
  status) home_status ;;
  update) shift; home_update "$@" ;;
  config) shift; config_command home "$@" ;;
  history) home_history ;;
  revert) shift; home_revert "$@" ;;
  os) shift; os_command "$@" ;;
  env) shift; env_shell "$@" ;;
  help|-h|--help) usage ;;
  *) say "unknown command '$1'"; usage >&2; exit 1 ;;
esac
