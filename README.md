# smudgenix

Bootstraps and keeps a system up to date. Host-specific config lives in a
small, uncommitted per-host flake; user-level (sudo-free) home-manager config
lives in a small, uncommitted per-home flake. Both build on this repo.

```
github:smudge/smudgenix ─┬─► /etc/nixos/flake.nix              (per-host)  → sudo nixos-rebuild switch
                         └─► ~/.config/home-manager/flake.nix  (per-home)  → home-manager switch
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

To update manually:

```bash
/etc/nixos/rebuild_flake.sh            # regenerates flake.lock, then switches
~/.config/home-manager/rebuild_flake.sh # same, for the home flake
```

Both (and the daily home update) use your `gh` login, if any, to avoid GitHub
rate limits.

For local iteration, point either per-host flake's input at a checkout with
`path:/path/to/checkout` instead of the GitHub URL.
