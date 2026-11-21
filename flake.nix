#  flake.nix *
#   ├─ ./nixos
#   │   └─ default.nix
#   ├─ ./macos
#   │   └─ default.nix
#   ├─ ./nix
#   │   └─ default.nix
#   └─ ./template
#       └─ flake.nix   (per-host, uncommitted /etc/nixos flake)

{
  description = "An all-in-one tool for managing Nix, NixOS, and macOS systems";

  inputs = {
    # nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:nixos/nixos-hardware/master";
    nix-darwin = { url = "github:nix-darwin/nix-darwin"; inputs.nixpkgs.follows = "nixpkgs"; };
    codex-cli-nix.url = "github:sadjow/codex-cli-nix";
  };

  outputs = inputs @ { self, nixpkgs, nixos-hardware, nix-darwin, ... }: {
    hardware = nixos-hardware;

    nixosConfigurations = (import ./nixos {
      inherit inputs nixpkgs;
    });

    macosConfigurations = (import ./macos {
      inherit inputs nixpkgs nix-darwin;
    });

    nixConfigurations = (import ./nix {
      inherit inputs nixpkgs;
    });

    # cd /etc/nixos && sudo nix flake init -t github:smudge/smudgenix
    templates.default = {
      path = ./template;
      description = "Per-host NixOS flake (lives uncommitted in /etc/nixos)";
    };
  };
}
