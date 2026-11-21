# NixOS front-end. Hosts configure it through typed `smudgenix.*` options
# (plus native NixOS options such as networking.hostName, time.timeZone and
# system.stateVersion).
{ inputs, nixpkgs }:

let
  module = {
    imports = [
      ./user.nix
      ./boot.nix
      ./core.nix
      ./auto_update.nix
      ./connectivity.nix
      ./audio.nix
      ./display.nix
      ./inputs.nix
      ./desktop.nix
      ./userland.nix
      ./gaming.nix
    ];
  };
in
{
  inherit module;

  mkSystem = {
    modules ? [],
  }: nixpkgs.lib.nixosSystem {
    modules = [ module ] ++ modules;
  };
}
