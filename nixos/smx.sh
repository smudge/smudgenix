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

# The config commands, the same for your home and the OS.
config_usage() {
  cat <<EOF2
  config                  Browse the settings, and change them
  config list [--all]     The settings changed here (or all, with their values)
  config get <key>        A setting's value
  config set <key> <value> [--apply]
  config unset <key>      Back to the default
  config edit [--nix]     Edit smudgenix.toml (or, with --nix, flake.nix)
  config diff             What \`config apply\` would change
  config reset            Discard the changes since the last apply
EOF2
}

usage() {
  cat <<EOF2
Usage: smx <command> [args]

Your home ($(tildify "$home_flake")):
  status                  Show your home's status
  update                  Get the latest, and apply it
$(config_usage)
  config apply            Apply the changes (without updating); --local
                          <checkout> uses that smudgenix instead
  history                 List your home's generations
  revert [<gen>]          Go back to the previous generation, or to <gen>

The OS (/etc/nixos), shared by every user:
  os ...                  The same commands, for the OS (see \`smx os help\`)

Tools:
  shell <pkg>... [-- <cmd>]
                          A shell with these packages (from the OS's nixpkgs)
  run <pkg> [args]        Run a package's program, without installing it
  search <words>          Find packages
  clean [<days>d]         Delete your generations older than that (14d), and
                          then what nothing uses any more
  env [<shell> [-f]]      Write a .envrc using a devShell from $(tildify "$devshells"),
                          or list them
  help                    Show this help
EOF2
}

os_usage() {
  cat <<EOF2
Usage: smx os <command> [args]

The OS (/etc/nixos), shared by every user. Changing it takes sudo.

  status                  Show the OS's status
  update [when]           Get the latest, and apply it
$(config_usage)
  config apply [when]     Apply the changes (without updating); --local
                          <checkout> uses that smudgenix instead
  history                 List the OS's generations
  revert [<gen>] [when]   Go back to the previous generation, or to <gen>
  upgrade                 Move to the next smudgenix release
  clean [<days>d]         Delete the OS's generations older than that (14d),
                          and then what nothing uses any more

[when] is when it takes effect: now and for good (by default), or
  --try                   now, until the next reboot
  --on-reboot             at the next reboot, and for good
EOF2
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
  snapshot home
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
  if [ -d "$(applied_dir home)" ] && file_changes home >/dev/null; then
    echo "  Your config has changes that aren't applied yet: \`smx config diff\`."
  fi
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

# Only admins (members of wheel) can change the OS.
need_admin() {
  [ "$(id -u)" -ne 0 ] || return 0
  id -nG | tr ' ' '\n' | grep -qx wheel \
    || die "changing the OS takes an admin (a member of wheel); ask one to run \`smx ${args[*]}\`"
}

# Re-run this command as root (it changes the OS).
as_root() {
  [ "$(id -u)" -ne 0 ] || return 0
  need_admin
  github_token
  exec sudo --preserve-env=NIX_CONFIG "$0" "${args[@]}"
}

os_apply() {
  parse_apply_args "$@"
  as_root
  overrides=()
  [ -z "$checkout" ] || overrides=(--override-input nixos "path:$checkout")
  nixos-rebuild "$when" --flake "$os_flake" "${overrides[@]}" "${extra[@]}"
  if [ "$when" != test ]; then
    rm -f "$os_state/os-reverted"
    snapshot os
  fi
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
  if [ -d "$(applied_dir os)" ] && file_changes os >/dev/null; then
    echo "  The config has changes that aren't applied yet: \`smx os config diff\`."
  fi
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

# --- Config: smudgenix.toml, next to each flake ----------------------------
#
# Each command takes a scope, "home" or "os", first.

flake_of() { if [ "$1" = os ]; then echo "$os_flake"; else echo "$home_flake"; fi; }
state_of() { if [ "$1" = os ]; then echo "$os_state"; else echo "$home_state"; fi; }
prefix_of() { if [ "$1" = os ]; then echo "smx os"; else echo "smx"; fi; }
settings_of() { echo "$(flake_of "$1")/smudgenix.toml"; }

# The flake attribute of this scope's config (worked out once per run).
config_attr() {
  if [ -n "${config_attr_cache:-}" ]; then echo "$config_attr_cache"; return; fi
  if [ "$1" = home ]; then
    echo "homeConfigurations.\"$USER\""
    return
  fi
  host=$(cat /proc/sys/kernel/hostname)
  names=$(nix eval --json "$os_flake#nixosConfigurations" --apply builtins.attrNames 2>/dev/null) \
    || die "can't read $os_flake/flake.nix"
  if echo "$names" | jq -e --arg h "$host" 'index($h)' >/dev/null; then
    echo "nixosConfigurations.\"$host\""
  elif [ "$(echo "$names" | jq length)" = 1 ]; then
    echo "nixosConfigurations.\"$(echo "$names" | jq -r '.[0]')\""
  else
    die "$os_flake has no config named $host (only $(echo "$names" | jq -r 'join(", ")'))"
  fi
}

# Ask ./smx-eval.nix about this scope's options (see there): $2 is a Nix
# request, e.g. '{ list = true; }'. Prints JSON, or the error and fails.
ask() {
  err=$(mktemp)
  if ! nix eval --impure --json "$(flake_of "$1")#$(config_attr "$1")" \
      --apply "c: import $smx_eval c $2" 2>"$err"; then
    grep -v '^warning:' "$err" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
}

# A key ("desktop.binds.\"Mod+T\"") as a JSON path (["desktop","binds","Mod+T"]).
key_path() {
  jq -cn --arg k "$1" '[$k | scan("\"[^\"]*\"|[^.\"]+") | ltrimstr("\"") | rtrimstr("\"")]'
}

# A JSON path as a key.
path_key() {
  jq -r 'map(if test("^[A-Za-z0-9_-]+$") then . else tojson end) | join(".")' <<<"$1"
}

# One option's details (see ./smx-eval.nix), or die explaining why not.
describe() {
  path=$(key_path "$2")
  info=$(ask "$1" "{ path = builtins.fromJSON ''$path''; }") || exit 1
  if [ "$(jq -r '.error // empty' <<<"$info")" = unknown ]; then
    # Maybe it's the other side's.
    other=$([ "$1" = os ] && echo home || echo os)
    if [ -f "$(flake_of "$other")/flake.nix" ] \
      && elsewhere=$(config_attr_cache="" ask "$other" "{ path = builtins.fromJSON ''$path''; }" 2>/dev/null) \
      && [ -z "$(jq -r '.error // empty' <<<"$elsewhere")" ]; then
      die "$2 is $([ "$other" = os ] && echo "the OS's, shared by every user" || echo "your home's"): see \`$(prefix_of "$other") config get $2\`"
    fi
    say "there's no setting $2"
    suggestions=$(jq -r '.suggestions | .[0:8] | join("\n  ")' <<<"$info")
    [ -z "$suggestions" ] || echo "Did you mean:"$'\n'"  $suggestions" >&2
    exit 1
  fi
  echo "$info"
}

settings_json() {
  file=$(settings_of "$1")
  if [ -s "$file" ]; then remarshal -if toml -of json "$file"; else echo '{}'; fi
}

# Write this scope's file $2 from stdin (as root, via sudo, for the OS).
write_file() {
  if [ "$1" = os ] && [ "$(id -u)" -ne 0 ]; then
    need_admin
    sudo tee "$2" >/dev/null
  else
    cat > "$2"
  fi
}

write_settings() {
  {
    echo "# smudgenix settings, written by \`$(prefix_of "$1") config set\`. Each one is a"
    echo "# smudgenix option, and wins over the same option set in flake.nix."
    echo "# (Comments here aren't kept.)"
    echo
    remarshal -if json -of toml
  } | write_file "$1" "$(settings_of "$1")"
}

# Fail unless this config reads smudgenix.toml.
needs_settings_file() {
  if [ "$(jq -r '.settingsFile // empty' <<<"$2")" = "" ]; then
    say "$(tildify "$(flake_of "$1")")/flake.nix doesn't read smudgenix.toml yet. Add"
    say "  settings = ./smudgenix.toml;"
    die "to its $([ "$1" = os ] && echo mkSystem || echo mkHome) { … }, then try again."
  fi
}

# A value from the command line, as JSON for the option's type.
parse_value() {
  info=$1 raw=$2
  type=$(jq -r .type <<<"$info")
  if [ "$(jq -r '.inner | length' <<<"$info")" = 0 ]; then
    case "$(jq -r .typeName <<<"$info")" in
      str|nonEmptyStr|singleLineStr|strMatching|enum|separatedString|lines|passwdEntry)
        jq -n --arg v "$raw" '$v'; return ;;
      bool)
        case "$raw" in
          true|yes|on|1) echo true ;;
          false|no|off|0) echo false ;;
          *) die "$(jq -r .key <<<"$info") is $type: true or false" ;;
        esac
        return ;;
      package)
        die "packages can't go in smudgenix.toml; set $(jq -r .key <<<"$info") in flake.nix (\`config edit --nix\`)" ;;
    esac
  fi
  if value=$(jq -c . <<<"$raw" 2>/dev/null) && [ -n "$value" ]; then
    [ "$value" != null ] || die "to clear a setting, use \`config unset\`"
    echo "$value"
  else
    jq -n --arg v "$raw" '$v'
  fi
}

# Shows a value: strings bare, everything else as JSON.
show_value() { jq -r 'if type == "string" then . else tojson end' <<<"$1"; }

config_get() {
  [ $# = 1 ] || die "usage: $(prefix_of "$scope") config get <key>"
  info=$(describe "$scope" "$1")
  # Unset in a home: the OS's value applies.
  if [ "$scope" = home ] && [ "$(jq -c .value <<<"$info")" = null ] && [ -f "$os_flake/flake.nix" ] \
    && os_info=$(config_attr_cache="" ask os "{ path = builtins.fromJSON ''$(key_path "$1")''; }" 2>/dev/null) \
    && [ -z "$(jq -r '.error // empty' <<<"$os_info")" ]; then
    show_value "$(jq -c .value <<<"$os_info")"
    [ ! -t 1 ] || echo "  (the OS's; unset here)" >&2
    return
  fi
  show_value "$(jq -c .value <<<"$info")"
  if [ -t 1 ]; then
    jq -r '"  (\(if .origin == "default" then "the default" else "from \(.origin)" end); \(.type); default \(.default))"' <<<"$info" >&2
  fi
}

config_list() {
  if [ "${1:-}" = --all ]; then
    ask "$scope" '{ list = true; }' | jq -r '.[] | "\(.key) = \(.value | if . == null then "(unset)" elif type == "string" then . else tojson end | .[0:70])\(if .origin == "default" then "" else "  (\(.origin))" end)"'
    return
  fi
  [ $# = 0 ] || die "usage: $(prefix_of "$scope") config list [--all]"
  settings_json "$scope" | jq -c '. as $s | [paths(type != "object")]
    | map(select(all(.[]; type == "string")))[] | . as $p | [$p, ($s | getpath($p))]' | while read -r pair; do
    echo "$(path_key "$(jq -c '.[0]' <<<"$pair")") = $(show_value "$(jq -c '.[1]' <<<"$pair")")"
  done
}

config_set() {
  apply=""
  rest=()
  for a in "$@"; do [ "$a" = --apply ] && apply=1 || rest+=("$a"); done
  [ ${#rest[@]} = 2 ] || die "usage: $(prefix_of "$scope") config set <key> <value> [--apply]"
  key=${rest[0]}
  info=$(describe "$scope" "$key")
  needs_settings_file "$scope" "$info"
  value=$(parse_value "$info" "${rest[1]}")
  path=$(key_path "$key")
  old=$(settings_json "$scope")
  jq --argjson p "$path" --argjson v "$value" 'setpath($p; $v)' <<<"$old" | write_settings "$scope"
  # Check the config takes it; if not, put the file back.
  if ! check=$(ask "$scope" "{ check = builtins.fromJSON ''$path''; }" 2>&1); then
    write_settings "$scope" <<<"$old"
    echo "$check" | tail -5 >&2
    die "$key can't be $(show_value "$value"); left it as it was"
  fi
  say "$key = $(show_value "$value")"
  if [ -n "$apply" ]; then
    config_apply_now
  else
    say "(not applied yet: \`$(prefix_of "$scope") config apply\`)"
  fi
}

config_unset() {
  [ $# = 1 ] || die "usage: $(prefix_of "$scope") config unset <key>"
  path=$(key_path "$1")
  old=$(settings_json "$scope")
  if [ "$(jq --argjson p "$path" 'getpath($p) == null' <<<"$old")" = true ]; then
    info=$(describe "$scope" "$1")
    if [ "$(jq -r .origin <<<"$info")" = flake.nix ]; then
      die "$1 isn't in smudgenix.toml: it's set in flake.nix (\`$(prefix_of "$scope") config edit --nix\`)"
    fi
    die "$1 isn't set, so it's already the default"
  fi
  jq --argjson p "$path" 'delpaths([$p])
    | walk(if type == "object" then with_entries(select(.value != {})) else . end)' <<<"$old" \
    | write_settings "$scope"
  say "$1 is back to its default (not applied yet: \`$(prefix_of "$scope") config apply\`)"
}

# Whether this config builds, after an edit.
config_check() {
  say "checking…"
  if [ "$1" = os ]; then
    ask os '{ path = [ "settingsFile" ]; } // { _ = c.config.system.build.toplevel.drvPath; }' >/dev/null 2>&1 || true
    target="$(flake_of os)#$(config_attr os).config.system.build.toplevel.drvPath"
  else
    target="$(flake_of home)#$(config_attr home).activationPackage.drvPath"
  fi
  if ! err=$(nix eval --raw "$target" 2>&1 >/dev/null); then
    echo "$err" | grep -v '^warning:' | tail -15 >&2
    die "that doesn't work yet; fix it with \`$(prefix_of "$1") config edit\`"
  fi
}

config_edit() {
  file=$(settings_of "$scope")
  case "${1:-}" in
    --nix) file="$(flake_of "$scope")/flake.nix" ;;
    "") [ -e "$file" ] || echo '{}' | write_settings "$scope" ;;
    *) die "usage: $(prefix_of "$scope") config edit [--nix]" ;;
  esac
  before=$(cat "$file")
  if [ "$scope" = os ]; then
    need_admin
    sudoedit "$file"
  else
    read -ra editor <<<"${VISUAL:-${EDITOR:-vi}}"
    "${editor[@]}" "$file"
  fi
  if [ "$(cat "$file")" = "$before" ]; then
    say "no changes"
    return
  fi
  config_check "$scope"
  if [ -t 0 ] && confirm "Apply it now?"; then
    config_apply_now
  else
    say "(not applied yet: \`$(prefix_of "$scope") config apply\`)"
  fi
}

# A copy of the config as last applied, for `config diff` and `reset`.
applied_dir() { echo "$(state_of "$1")/applied"; }

snapshot() {
  dir=$(applied_dir "$1")
  mkdir -p "$dir"
  for f in flake.nix smudgenix.toml; do
    if [ -e "$(flake_of "$1")/$f" ]; then cp "$(flake_of "$1")/$f" "$dir/$f"; else rm -f "$dir/$f"; fi
  done
}

# The changes to the config files since the last apply (none: fails).
file_changes() {
  dir=$(applied_dir "$1") changed=1
  for f in flake.nix smudgenix.toml; do
    a="$dir/$f" b="$(flake_of "$1")/$f"
    [ -e "$a" ] || a=/dev/null
    [ -e "$b" ] || b=/dev/null
    diff -u --label "$f (applied)" --label "$f" "$a" "$b" && continue
    changed=0
  done
  return $changed
}

config_diff() {
  [ $# = 0 ] || die "usage: $(prefix_of "$scope") config diff"
  current=$(readlink -e "$([ "$scope" = os ] && echo "$os_profile" || echo "$home_profile")") \
    || { echo "Nothing applied yet: \`$(prefix_of "$scope") config apply\` applies it all."; return; }
  if [ -d "$(applied_dir "$scope")" ]; then
    if ! file_changes "$scope"; then
      echo "Nothing to apply."
      return
    fi
    echo
  else
    say "there's no record of what was applied last (one's kept from the next apply)"
  fi
  say "building, to compare packages…"
  if [ "$scope" = os ]; then
    new=$(nix build --no-link --print-out-paths "$os_flake#$(config_attr os).config.system.build.toplevel")
  else
    new=$(nix build --no-link --print-out-paths "$home_flake#$(config_attr home).activationPackage")
  fi
  changes=$(nix store diff-closures "$current" "$new")
  if [ -n "$changes" ]; then echo "$changes"; else echo "No package changes."; fi
}

config_reset() {
  force=""
  [ "${1:-}" != -f ] || force=1
  dir=$(applied_dir "$scope")
  [ -d "$dir" ] || die "there's no record of what was applied last (one's kept from the next apply)"
  if ! file_changes "$scope"; then
    echo "Nothing to reset."
    return
  fi
  if [ -z "$force" ]; then
    [ -t 0 ] || die "run it in a terminal to confirm, or with -f"
    confirm "Discard these changes?" || exit 1
  fi
  # (Kept, in case.)
  backup="$home_state/discarded/$scope-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup"
  for f in flake.nix smudgenix.toml; do
    target="$(flake_of "$scope")/$f"
    [ ! -e "$target" ] || cp "$target" "$backup/$f"
    if [ -e "$dir/$f" ]; then
      write_file "$scope" "$target" < "$dir/$f"
    elif [ -e "$target" ]; then
      if [ "$scope" = os ] && [ "$(id -u)" -ne 0 ]; then sudo rm "$target"; else rm "$target"; fi
    fi
  done
  say "discarded (kept in $(tildify "$backup"))"
}

# Browse every setting (with fzf), and change some.
config_browse() {
  if ! [ -t 0 ] || ! [ -t 1 ]; then
    config_list --all
    return
  fi
  list=$(mktemp)
  trap 'rm -f "$list"' EXIT
  changed=""
  # (Each change runs as its own smx, so a mistake stops just that change.)
  self=("$0")
  [ "$scope" != os ] || self+=(os)
  while true; do
    say "reading the settings…"
    ask "$scope" '{ list = true; }' > "$list" || exit 1
    # shellcheck disable=SC2016
    key=$(jq -r '.[] | "\(.key)\t\(.value | if . == null then "(unset)" elif type == "string" then . else tojson end | .[0:60])\t\(if .origin == "default" then "" else .origin end)"' "$list" \
      | awk -F'\t' '{ printf "%-36s %-62s %s\n", $1, $2, $3 }' \
      | fzf --no-sort --reverse --prompt "$(prefix_of "$scope") config> " \
          --header "Enter: change   Esc: done" \
          --preview "jq -r --arg k {1} '.[] | select(.key == \$k) | \"\(.key)\n\n\(.description)\nType: \(.type)\nDefault: \(.default)\nValue: \(.value | tojson)\nFrom: \(.origin)\"' $list" \
          --preview-window down,40%,wrap \
      | awk '{ print $1 }') || break
    [ -n "$key" ] || break
    current=$(jq -r --arg k "$key" '.[] | select(.key == $k) | .value | if type == "string" then . else tojson end' "$list")
    echo "$key (empty: leave it; -: back to the default)"
    read -r -e -i "$current" -p "  = " value || break
    if [ "$value" = - ]; then
      if "${self[@]}" config unset "$key"; then changed=1; fi
    elif [ -n "$value" ] && [ "$value" != "$current" ]; then
      if "${self[@]}" config set "$key" "$value"; then changed=1; fi
    fi
  done
  if [ -n "$changed" ] && confirm "Apply the changes now?"; then
    config_apply_now
  fi
}

confirm() {
  read -r -p "$1 [y/N] " answer
  case "$answer" in y|Y|yes) return 0 ;; *) return 1 ;; esac
}

config_apply_now() { "${scope}_apply"; }

config_command() {
  scope=$1; shift
  config_attr_cache=$(config_attr "$scope")
  case "${1:-}" in
    "") config_browse ;;
    list) shift; config_list "$@" ;;
    get) shift; config_get "$@" ;;
    set) shift; config_set "$@" ;;
    unset) shift; config_unset "$@" ;;
    edit) shift; config_edit "$@" ;;
    diff) shift; config_diff "$@" ;;
    reset) shift; config_reset "$@" ;;
    apply) shift; "${scope}_apply" "$@" ;;
    *) say "unknown command '$(prefix_of "$scope" | cut -c5-) config $1'"; die "see \`$(prefix_of "$scope") help\`" ;;
  esac
}

# --- Tools ----------------------------------------------------------------

# A package from the OS's nixpkgs ("ripgrep"), or any flake ref as is.
pkg_ref() { case "$1" in *#*|*:*) echo "$1" ;; *) echo "nixpkgs#$1" ;; esac; }

# Unfree packages, too, where the OS allows them ($allow_unfree, from
# ./smx.nix). (Nix only reads that from the environment, in impure mode.)
nix_pkgs() {
  if [ -n "$allow_unfree" ]; then
    NIXPKGS_ALLOW_UNFREE=1 nix "$1" --impure "${@:2}"
  else
    nix "$@"
  fi
}

shell_with() {
  refs=() cmd=()
  while [ $# -gt 0 ]; do
    if [ "$1" = -- ]; then shift; cmd=("$@"); break; fi
    refs+=("$(pkg_ref "$1")")
    shift
  done
  [ ${#refs[@]} -gt 0 ] || die "usage: smx shell <package>... [-- <command>]"
  if [ ${#cmd[@]} -gt 0 ]; then
    nix_pkgs shell "${refs[@]}" --command "${cmd[@]}"
  else
    say "a shell with ${refs[*]#nixpkgs#} (exit to leave)"
    nix_pkgs shell "${refs[@]}"
  fi
}

run_pkg() {
  [ $# -ge 1 ] || die "usage: smx run <package> [args]"
  pkg=$1; shift
  [ "${1:-}" != -- ] || shift
  nix_pkgs run "$(pkg_ref "$pkg")" -- "$@"
}

search_pkgs() {
  [ $# -ge 1 ] || die "usage: smx search <words>"
  [ ! -t 1 ] || say "searching (the first search after an update takes a while)…"
  nix search nixpkgs "$@" --json \
    | jq -r 'to_entries[] | (.key | sub("^legacyPackages\\.[^.]+\\."; "")) as $name
        | "\($name) \(.value.version)\(if .value.description != "" then "\n    \(.value.description)" else "" end)"'
}

# Generations of profile $1 that `clean` with age $2 (like 14d) deletes:
# older than that, and not the current one.
old_generations() {
  cutoff=$(( $(date +%s) - ${2%d} * 86400 ))
  current=$(current_generation "$1")
  for link in "$1"-*-link; do
    [ -e "$link" ] || continue
    n=${link##"$1"-}; n=${n%-link}
    if [ "$n" != "$current" ] && [ "$(stat -c %Y "$link")" -lt "$cutoff" ]; then echo "$n"; fi
  done | sort -n | tr '\n' ' '
}

# Delete generations older than an age (14d by default), and then whatever
# nothing uses any more.
clean() {
  scope=$1; shift
  age=14d force=""
  for a in "$@"; do
    case "$a" in
      -f) force=1 ;;
      [0-9]*d) age=$a ;;
      *) die "usage: $(prefix_of "$scope") clean [<days>d] [-f]" ;;
    esac
  done
  profile=$([ "$scope" = os ] && echo "$os_profile" || echo "$home_profile")
  old=$(old_generations "$profile" "$age")
  if [ -n "$old" ]; then
    echo "Deletes generations ${old% } (older than ${age%d} days); \`revert\` can't go back to them after."
  else
    echo "No generations are older than ${age%d} days; deletes only what nothing uses."
  fi
  if [ -z "$force" ]; then
    [ -t 0 ] || die "run it in a terminal to confirm, or with -f"
    confirm "Go ahead?" || exit 1
  fi
  if [ "$scope" = os ]; then
    # (Confirmed already: as root, it goes ahead.)
    args+=(-f)
    as_root
    nix-collect-garbage --delete-older-than "$age"
    # (And drop them from the boot menu.)
    "$os_profile/bin/switch-to-configuration" boot
  else
    nix-collect-garbage --delete-older-than "$age"
  fi
}

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

os_command() {
  case "${1:-}" in
    "") os_usage; echo; os_status ;;
    status) os_status ;;
    update) shift; os_update "$@" ;;
    config) shift; config_command os "$@" ;;
    history) os_history ;;
    revert) shift; os_revert "$@" ;;
    upgrade) os_upgrade ;;
    clean) shift; clean os "$@" ;;
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
  shell) shift; shell_with "$@" ;;
  run) shift; run_pkg "$@" ;;
  search) shift; search_pkgs "$@" ;;
  clean) shift; clean home "$@" ;;
  env) shift; env_shell "$@" ;;
  help|-h|--help) usage ;;
  *) say "unknown command '$1'"; usage >&2; exit 1 ;;
esac
