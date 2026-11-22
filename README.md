# smudgenix

Bootstraps and keeps a system up to date. Host-specific config lives in a
small, uncommitted per-host flake; user-level (sudo-free) home-manager config
lives in a small, uncommitted per-home flake. Both build on this repo.

```
github:smudge/smudgenix ─┬─► /etc/nixos/flake.nix              (per-host)  → smx os config apply
                         └─► ~/.config/home-manager/flake.nix  (per-home)  → smx config apply
```

## NixOS

Generate the per-host flake next to your `hardware-configuration.nix`, then
fill it in (hostname, `system.stateVersion`, `smudgenix.*` options, hardware
module, overrides):

```bash
cd /etc/nixos
sudo nix --extra-experimental-features 'nix-command flakes' flake init -t github:smudge/smudgenix
sudoedit /etc/nixos/flake.nix
sudo nixos-rebuild switch
```

On each user's first login, a user service generates
`~/.config/home-manager/flake.nix` from the `smudgenix.user.homeTemplate`
template (default: `github:smudge/smudgenix#home`) and applies it, so every
user manages their own home without sudo. It never clones or overwrites
anything; edit that file for per-home overrides. The primary user's git
identity is pre-filled from `smudgenix.user.git` if set; otherwise you are
notified to fill it in, and it is applied on the next update. The generated
flake follows the system's smudgenix (via `/etc/nixos/flake.lock`), so home
and system share one smudgenix and nixpkgs, and update in lockstep.


Systems are flake-only: channels are disabled, and `<nixpkgs>` (e.g. for
`nix-shell -p`) resolves to the system's flake-pinned nixpkgs.

## Userland only (any Nix-enabled home)

On macOS, another distro, or anywhere without sudo, use just the home-manager
half. Fill in the `@placeholders@`, including your git identity (required), and
`stateVersion` (the current home-manager release, e.g. from
`home-manager --version`), then apply:

```bash
mkdir -p ~/.config/home-manager && cd ~/.config/home-manager
nix flake init -t github:smudge/smudgenix#home
$EDITOR flake.nix
nix run home-manager -- switch
```

## Updates

Updates are driven by what is pushed upstream:

- `nixos-upgrade.timer` refreshes `/etc/nixos/flake.lock` and rebuilds daily, at
  `smudgenix.autoUpdate.time` (default `"04:00"`) in `time.timeZone`, or at any
  systemd calendar spec given as `smudgenix.autoUpdate.dates`.
  It never reboots unless `smudgenix.autoUpdate.reboot = true`; instead, the
  primary user gets a desktop notification when an update needs a reboot.
- `home-manager-auto-update` (user) refreshes
  `~/.config/home-manager/flake.lock` and re-applies right after each system
  switch (picking up the system's new smudgenix), and daily.

## smx

`smx`, installed for every user, works on your home, and never needs sudo.
`smx os` works on the OS, shared by every user, and asks for sudo only to
change it. `smx help` and `smx os help` list everything.

```bash
smx update          # get the latest (the OS's smudgenix) for your home, and apply it
smx config          # browse your settings, and change them
smx config set dev.enable false
smx config diff     # what applying would change
smx config apply    # apply your changes
smx history         # your home's generations
smx revert [<gen>]  # back to the previous generation, or to <gen>

smx os update       # regenerate /etc/nixos/flake.lock, and apply it
smx os config set hiDPI true
smx os config apply
smx os revert [<gen>]
```

The OS commands take `--try` (only until the next reboot) or `--on-reboot`
(from the next reboot). After a revert, automatic updates wait until the next
`update` or `config apply`.

The OS sets everyone's defaults, and each home can change the desktop's
for itself: `smx config set desktop.touchpad.tapToClick true`, or keyboard
repeat, keybinds (`desktop.binds`) and Noctalia's settings
(`desktop.noctalia.settings`). Unset, they're the OS's.

`config set` writes `smudgenix.toml`, next to the flake (which reads it with
`settings = ./smudgenix.toml;`). Its keys are `smudgenix.*` options, checked
against their types, and they win over the same options set in `flake.nix`.
For anything else, `config edit --nix` edits `flake.nix` itself, and checks
it before applying. `config reset` puts both back as they were last applied.

Updates use your `gh` login, if any, to avoid GitHub rate limits.

For local iteration, `config apply --local <checkout>` uses a smudgenix
checkout instead of the locked one.
