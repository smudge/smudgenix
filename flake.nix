{
  description = "My NixOS configuration";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs, ... }: {
    nixosConfigurations = {
      default = {
        hardwareConfigPath ? "/etc/nixos/hardware-configuration.nix"
      }: nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./configuration.nix
          (if builtins.pathExists hardwareConfigPath then import hardwareConfigPath else {})
        ];
      };
    };
  };
}
