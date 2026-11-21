# Userland (home-manager) front-end: usable from any Nix-enabled home folder,
# on NixOS or not, without sudo.
{ inputs, nixpkgs }:

let
  homeModule = {
    imports = [
      inputs.nixvim.homeModules.nixvim
      ./modules
    ];
  };
in
{
  # The opinionated defaults, for composing manually.
  homeModules.default = homeModule;

  # Build a homeConfiguration for a given user/system (see ../template/home).
  mkHome = {
    username,
    system,
    # The home-manager release this home was first set up with. Never change
    # it after setup.
    stateVersion,
    homeDirectory ? null,
    modules ? [],
  }: let
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };
    defaultHome =
      if pkgs.stdenv.hostPlatform.isDarwin then "/Users/${username}" else "/home/${username}";
  in inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      homeModule
      {
        home.username = username;
        home.homeDirectory =
          if homeDirectory != null then homeDirectory else defaultHome;
        home.stateVersion = stateVersion;
      }
    ] ++ modules;
  };
}
