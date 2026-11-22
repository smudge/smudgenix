# NixOS front-end. Hosts configure it through typed `smudgenix.*` options
# (plus native NixOS options such as networking.hostName, time.timeZone and
# system.stateVersion).
{ nixpkgs }:

let
  settingsModule = import ../settings.nix { inherit (nixpkgs) lib; };

  module = {
    imports = [
      settingsModule.module
      ./user.nix
      ./boot.nix
      ./core.nix
      ./auto_update.nix
      ./connectivity.nix
      ./audio.nix
      ./display.nix
      ./inputs.nix
      ./desktop
      ./userland.nix
      ./smx.nix
      ./gaming.nix
    ];
  };
in
{
  inherit module;

  mkSystem = {
    # The host's smudgenix.toml (written by `smx os config`), if any.
    settings ? null,
    modules ? [],
  }: nixpkgs.lib.nixosSystem {
    modules = [ module ]
      ++ nixpkgs.lib.optional (settings != null) (settingsModule.fromFile settings)
      ++ modules;
  };
}
