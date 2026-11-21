{ inputs, nixpkgs }:

let
  lib = nixpkgs.lib;
  nixosSystem = nixpkgs.lib.nixosSystem;
in
{
  default = {
    vars,
    system ? "x86_64-linux",
    extraModules ? [],
  }: nixosSystem {
    inherit system;
    modules = [
      (import ./boot.nix { inherit vars; })
      (import ./core.nix { inherit vars; })
      (import ./auto_update.nix { inherit vars; })
      (import ./connectivity.nix { inherit vars; })
      (import ./audio.nix { inherit vars; })
      (import ./display.nix { inherit vars; })
      (import ./i18n.nix { inherit vars; })
      (import ./inputs.nix { inherit vars; })
      (import ./desktop.nix { inherit vars; })
      (import ./userland.nix { inherit vars; })
      (import ./gaming.nix { inherit vars; })
      ({ config, pkgs, ... }: {
        networking.hostName = vars.hostname;
        time.timeZone = lib.mkIf (vars ? timezone) vars.timezone;

        users.users.${vars.user.name} = {
          isNormalUser = true;
          description = vars.user.description;
          extraGroups = [ "networkmanager" "wheel" "lp" "input" "video"];
          packages = [
            inputs.codex-cli-nix.packages.${system}.default
          ];
        };

        # The NixOS release this host was first installed with (see
        # `man configuration.nix`). Host-specific, and should never change.
        system.stateVersion = vars.stateVersion or (throw ''
          smudgenix: set `vars.stateVersion` in your host flake to the NixOS
          release this machine was first installed with (for a fresh install:
          "${lib.trivial.release}").
        '');
      })
    ] ++ extraModules;
  };
}
