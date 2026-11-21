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
# Pull in upstream changes with:
#
#   nix flake update && home-manager switch

{
  description = "Per-home home-manager config";

  inputs = {
    smudgenix.url = "github:smudge/smudgenix";

    # Optional: on a smudgenix NixOS host, share the system's pinned nixpkgs
    # (from /etc/nixos/flake.lock) instead of locking a separate one:
    # system.url = "path:/etc/nixos";
    # smudgenix.inputs.nixpkgs.follows = "system/nixos/nixpkgs";
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
          # Home-specific overrides & additions go here, e.g.:
          # smudgenix.ai.enable = false;
          # home.packages = [ pkgs.hello ];
        })
      ];
    };
  };
}
