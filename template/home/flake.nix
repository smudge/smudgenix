# Per-home home-manager flake.
#
# This file lives (uncommitted) at ~/.config/home-manager/flake.nix and holds
# everything specific to this machine/home. Create it with:
#
#   cd ~/.config/home-manager && nix flake init -t github:smudge/smudgenix#home
#
# then fill in the @placeholders@. Apply with:
#
#   home-manager switch
#
# Pull in upstream changes (regenerating flake.lock from scratch) with:
#
#   ~/.config/home-manager/rebuild_flake.sh

{
  description = "Per-home home-manager config";

  inputs = {
    smudgenix.url = "github:smudge/smudgenix";

    # On a smudgenix NixOS host, replace `smudgenix.url` with these to follow
    # the system's smudgenix (and its nixpkgs) from /etc/nixos/flake.lock, so
    # home and system update in lockstep:
    # system.url = "path:/etc/nixos";
    # smudgenix.follows = "system/nixos";
  };

  outputs = { smudgenix, ... }: {
    homeConfigurations."@username@" = smudgenix.lib.mkHome {
      username = "@username@";
      system = "@system@";
      # home-manager release this home was first set up with. Never change it
      # after setup:
      stateVersion = "@stateVersion@";
      modules = [
        ({ config, pkgs, lib, ... }: {
          # Required: your git identity.
          smudgenix.git = {
            name = "@gitName@";
            email = "@gitEmail@";
          };

          # Home-specific overrides & additions go here, e.g.:
          # smudgenix.ai.enable = false;
          # home.packages = [ pkgs.hello ];
          # programs.git.settings.pull.rebase = false;
          # programs.git.settings.alias.co = "checkout";
          # programs.git.ignores = [ ".envrc" ];
          # Adopt tweaks made in Noctalia's Settings (niri sessions):
          # smudgenix.noctalia.settings.bar.default.position = "bottom";
        })
      ];
    };
  };
}
