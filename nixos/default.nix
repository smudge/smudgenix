{ inputs, nixpkgs }:

let
  lib = nixpkgs.lib;
  nixosSystem = nixpkgs.lib.nixosSystem;
in
{
  default = {
    vars,
    extraModules ? []
  }: nixosSystem {
    system = "x86_64-linux";
    modules = [
      ./configuration.nix
      ({ config, pkgs, ... }: {
        networking.hostName = vars.hostname;

        users.users.${vars.username} = {
          isNormalUser = true;
          description = vars.userDescription;
          extraGroups = [ "networkmanager" "wheel" "lp" "input" ];
          packages = with pkgs; [
            home-manager
          ];
        };
      })
    ] ++ extraModules;
  };
}
