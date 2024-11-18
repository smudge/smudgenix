{
  description = "My NixOS configuration";

  inputs =
    {
      nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
      nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable"; # Unstable Nix Packages
      nixos-hardware.url = "github:nixos/nixos-hardware/master"; # Hardware Specific Configurations
    };

  outputs = { self, nixpkgs, nixpkgs-unstable, nixos-hardware, ... }: {
    hardware = nixos-hardware;
    nixosConfigurations = {
      default = {
        hostname,
        extraModules ? []
      }: nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./configuration.nix
          ({ config, ... }: {
            networking.hostName = hostname;
          })
        ] ++ extraModules;
      };
    };
  };
}
