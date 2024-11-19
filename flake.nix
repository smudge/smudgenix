{
  description = "My NixOS configuration";

  inputs =
    {
      nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
      nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
      nixos-hardware.url = "github:nixos/nixos-hardware/master";
    };

  outputs = { self, nixpkgs, nixpkgs-unstable, nixos-hardware, ... }: {
    hardware = nixos-hardware;
    nixosConfigurations = {
      default = {
        hostname,
        username,
        userDescription ? username,
        extraModules ? []
      }: nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./configuration.nix
          ({ config, pkgs, ... }: {
            networking.hostName = hostname;

            users.users.${username} = {
              isNormalUser = true;
              description = userDescription;
              extraGroups = [ "networkmanager" "wheel" "lp" "input" ];
              packages = with pkgs; [
                home-manager
              ];
            };
          })
        ] ++ extraModules;
      };
    };
  };
}
