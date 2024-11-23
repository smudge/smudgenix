{ inputs, nixpkgs }:

let
  lib = nixpkgs.lib;
  nixosSystem = nixpkgs.lib.nixosSystem;
in
{
  default = {
    hostname,
    username,
    userDescription,
    extraModules ? []
  }: nixosSystem {
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
}
