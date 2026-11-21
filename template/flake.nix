# Per-host NixOS flake.
#
# This file lives (uncommitted) at /etc/nixos/flake.nix alongside the
# generated hardware-configuration.nix, and holds everything specific to this
# machine. Apply with:
#
#   sudo nixos-rebuild switch
#
# Pull in upstream changes with:
#
#   sudo nix flake update --flake /etc/nixos && sudo nixos-rebuild switch

{
  description = "Per-host NixOS config";

  inputs.nixos.url = "github:smudge/smudgenix";

  outputs = { self, nixos }: {
    nixosConfigurations = let
      vars = {
        hostname = "<YOUR HOSTNAME HERE>";
        timezone = "UTC";
        hiDPI = false;
        user = {
          name = "<YOUR USERNAME HERE>";
          description = "<YOUR HUMAN NAME HERE>";
          # Home-manager flake used to bootstrap ~/.config/home-manager:
          # dotfiles = "github:smudge/dotfiles?dir=home-manager";
        };
      };
    in {
      ${vars.hostname} = nixos.outputs.nixosConfigurations.default {
        inherit vars;
        extraModules = [
          ./hardware-configuration.nix
          # nixos.hardware.nixosModules.<YOUR NIXOS HARDWARE TYPE>
          ({ config, pkgs, ... }: {
            # Host-specific overrides & additions go here.
          })
        ];
      };
      default = self.nixosConfigurations.${vars.hostname};
    };
  };
}
