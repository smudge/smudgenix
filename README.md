# smudgenix

Bootstraps and keeps a system up to date. Host-specific config lives in a
small, uncommitted per-host flake; user-level (sudo-free) config lives in a
separate home-manager flake.

```
github:smudge/smudgenix ──► /etc/nixos/flake.nix              (per-host)  → sudo nixos-rebuild switch
github:smudge/dotfiles  ──► ~/.config/home-manager/flake.nix  (per-home)  → home-manager switch
```

## NixOS

Generate the per-host flake next to your `hardware-configuration.nix`, then
fill in the vars (hostname, user, hardware module, overrides):

```bash
cd /etc/nixos
sudo nix --extra-experimental-features 'nix-command flakes' flake init -t github:smudge/smudgenix
sudoedit /etc/nixos/flake.nix
sudo nixos-rebuild switch
```

On first login, a user service generates `~/.config/home-manager/flake.nix`
from the `vars.user.dotfiles` template (default:
`github:smudge/dotfiles?dir=home-manager`) and applies it. It never clones or
overwrites anything; edit that file for per-home overrides.

## Updates

Updates are driven by what is pushed upstream:

- `nixos-upgrade.timer` refreshes `/etc/nixos/flake.lock` and rebuilds daily.
- `home-manager-auto-update.timer` (user) refreshes
  `~/.config/home-manager/flake.lock` and re-applies daily.

To update manually:

```bash
sudo nix flake update --flake /etc/nixos && sudo nixos-rebuild switch
cd ~/.config/home-manager && nix flake update && home-manager switch
```

For local iteration, point either per-host flake's input at a checkout with
`path:/path/to/checkout` instead of the GitHub URL.
