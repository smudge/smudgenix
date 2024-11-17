{
  description = "My NixOS configuration";

  inputs =
    {
      nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
      nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable"; # Unstable Nix Packages
      nixos-hardware.url = "github:nixos/nixos-hardware/master"; # Hardware Specific Configurations
    };

  outputs = { self, nixpkgs, nixpkgs-unstable, nixos-hardware, ... }: {
    nixosConfigurations = {
      default = {
        hardwareConfigPath ? "/etc/nixos/hardware-configuration.nix",
        hostname,
        nixosHardwareModule
      }: nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          (if builtins.pathExists hardwareConfigPath then import hardwareConfigPath else {})
          nixosHardwareModule
          ./configuration.nix
          ({ config, ... }: {
            networking.hostName = hostname;
          })
        ];
      };
    };
  };
}
