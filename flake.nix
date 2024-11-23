#  flake.nix *
#   ├─ ./nixos
#   │   └─ default.nix
#   ├─ ./macos
#   │   └─ default.nix
#   └─ ./nix
#       └─ default.nix

{
  description = "An all-in-one tool for managing Nix, NixOS, and macOS systems";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:nixos/nixos-hardware/master";
    nix-darwin = { url = "github:lnl7/nix-darwin/master"; inputs.nixpkgs.follows = "nixpkgs"; };
    home-manager = { url = "github:nix-community/home-manager"; inputs.nixpkgs.follows = "nixpkgs"; };
  };

  outputs = inputs @ { self, nixpkgs, nixpkgs-unstable, nixos-hardware, nix-darwin, home-manager, ... }: {
    hardware = nixos-hardware;

    nixosConfigurations = (import ./nixos {
      inherit inputs nixpkgs;
    });

    macosConfigurations = (import ./macos {
      inherit inputs nixpkgs nix-darwin;
    });

    nixConfigurations = (import ./nix {
      inherit inputs nixpkgs home-manager;
    });
  };
}
