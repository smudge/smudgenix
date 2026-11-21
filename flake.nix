#  flake.nix *
#   ├─ ./nixos        (NixOS system builder)
#   │   └─ default.nix
#   ├─ ./macos
#   │   └─ default.nix
#   ├─ ./nix          (userland home-manager config, for any Nix-enabled home)
#   │   ├─ default.nix
#   │   └─ modules/
#   └─ ./template
#       ├─ nixos/     (per-host, uncommitted /etc/nixos flake)
#       └─ home/      (per-home, uncommitted ~/.config/home-manager flake)

{
  description = "An all-in-one tool for managing Nix, NixOS, and macOS systems";

  inputs = {
    # nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:nixos/nixos-hardware/master";
    nix-darwin = { url = "github:nix-darwin/nix-darwin"; inputs.nixpkgs.follows = "nixpkgs"; };
    home-manager = { url = "github:nix-community/home-manager"; inputs.nixpkgs.follows = "nixpkgs"; };
    # nixvim pins (and is tested against) its own nixpkgs, so no `follows` here.
    nixvim.url = "github:nix-community/nixvim";
  };

  outputs = inputs @ { self, nixpkgs, nixos-hardware, nix-darwin, ... }: let
    nixos = import ./nixos { inherit inputs nixpkgs; };
    home = import ./nix { inherit inputs nixpkgs; };
  in {
    hardware = nixos-hardware;

    # NixOS: build a host (see ./template/nixos), or import the module into
    # your own nixosSystem. Configure via `smudgenix.*` options.
    lib.mkSystem = nixos.mkSystem;
    nixosModules.default = nixos.module;

    macosConfigurations = (import ./macos {
      inherit inputs nixpkgs nix-darwin;
    });

    # Userland: build a homeConfiguration (see ./template/home), or compose
    # the opinionated defaults manually.
    lib.mkHome = home.mkHome;
    homeModules.default = home.homeModules.default;

    templates = {
      # cd /etc/nixos && sudo nix flake init -t github:smudge/smudgenix
      default = self.templates.nixos;
      nixos = {
        path = ./template/nixos;
        description = "Per-host NixOS flake (lives uncommitted in /etc/nixos)";
      };
      # cd ~/.config/home-manager && nix flake init -t github:smudge/smudgenix#home
      home = {
        path = ./template/home;
        description = "Per-home home-manager flake (lives uncommitted in ~/.config/home-manager)";
      };
    };
  };
}
