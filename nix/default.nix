# Userland (home-manager) front-end: usable from any Nix-enabled home folder,
# on NixOS or not, without sudo.
{ inputs, nixpkgs }:

let
  settingsModule = import ../settings.nix { inherit (nixpkgs) lib; };

  homeModule = {
    imports = [
      settingsModule.module
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
    # The home's smudgenix.toml (written by `smx config`), if any.
    settings ? null,
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
    ]
      ++ nixpkgs.lib.optional (settings != null) (settingsModule.fromFile settings)
      ++ modules;
  };
}
