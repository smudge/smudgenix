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
fill in the vars (hostname, stateVersion, user, hardware module, overrides):

```bash
cd /etc/nixos
sudo nix --extra-experimental-features 'nix-command flakes' flake init -t github:smudge/smudgenix
sudoedit /etc/nixos/flake.nix
sudo nixos-rebuild switch
```

On first login, a user service generates `~/.config/home-manager/flake.nix`
from the `vars.user.homeTemplate` template (default:
`github:smudge/smudgenix#home`) and applies it. It never clones or
overwrites anything; edit that file for per-home overrides. The generated flake
follows the system's nixpkgs (via `/etc/nixos/flake.lock`), so home and system
share one nixpkgs.

Systems are flake-only: channels are disabled, and `<nixpkgs>` (e.g. for
`nix-shell -p`) resolves to the system's flake-pinned nixpkgs.

## Userland only (any Nix-enabled home)

On macOS, another distro, or anywhere without sudo, use just the home-manager
half. Fill in the `@placeholders@` (`stateVersion`: the current home-manager
release, e.g. from `home-manager --version`), then apply:

```bash
mkdir -p ~/.config/home-manager && cd ~/.config/home-manager
nix flake init -t github:smudge/smudgenix#home
$EDITOR flake.nix
nix run home-manager -- switch
```

## Updates

Updates are driven by what is pushed upstream:

- `nixos-upgrade.timer` refreshes `/etc/nixos/flake.lock` and rebuilds daily, at
  `vars.autoUpdateTime` (default `"04:00"`) in `vars.timezone`, or at any systemd
  calendar spec given as `vars.autoUpdateDates`.
- `home-manager-auto-update.timer` (user) refreshes
  `~/.config/home-manager/flake.lock` and re-applies daily.

To update manually:

```bash
sudo /etc/nixos/rebuild_flake.sh   # regenerates flake.lock, then switches
cd ~/.config/home-manager && nix flake update && home-manager switch
```

For local iteration, point either per-host flake's input at a checkout with
`path:/path/to/checkout` instead of the GitHub URL.
