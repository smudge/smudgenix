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

        # This value determines the NixOS release from which the default
        # settings for stateful data, like file locations and database versions
        # on your system were taken. It‘s perfectly fine and recommended to leave
        # this value at the release version of the first install of this system.
        # Before changing this value read the documentation for this option
        # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
        system.stateVersion = "24.05"; # Did you read the comment?
      })
    ] ++ extraModules;
  };
}
