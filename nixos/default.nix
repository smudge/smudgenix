{ inputs, nixpkgs }:

let
  lib = nixpkgs.lib;
  nixosSystem = nixpkgs.lib.nixosSystem;
in
{
  default = {
    vars,
    system ? "x86_64-linux",
    extraModules ? []
  }: nixosSystem {
    inherit system;
    modules = [
      (import ./boot.nix { inherit vars; })
      (import ./display.nix { inherit vars; })
      ./configuration.nix
      ({ config, pkgs, ... }: {
        networking.hostName = vars.hostname;
        time.timeZone = vars.timezone;

        users.users.${vars.user.name} = {
          isNormalUser = true;
          description = vars.user.description;
          extraGroups = [ "networkmanager" "wheel" "lp" "input" ];
          packages = with pkgs; [
            home-manager
          ];
        };
      })
    ] ++ extraModules;
  };
}
