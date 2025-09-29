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
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:nixos/nixos-hardware/master";
    nix-darwin = { url = "github:nix-darwin/nix-darwin/nix-darwin-25.05"; inputs.nixpkgs.follows = "nixpkgs"; };
    home-manager = { url = "github:nix-community/home-manager/release-25.05"; inputs.nixpkgs.follows = "nixpkgs"; };
  };

  outputs = inputs @ { self, nixpkgs, nixos-hardware, nix-darwin, home-manager, ... }: {
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
