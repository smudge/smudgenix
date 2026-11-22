{ lib, ... }:

{
  imports = [
    ./cli.nix
    ./git.nix
    ./shell.nix
    ./tmux.nix
    ./nvim.nix
    ./dev.nix
    ./ai.nix
    ./apps.nix
    ./noctalia.nix
  ];

  options.smudgenix = {
    dev.enable = lib.mkEnableOption "development toolchains" // { default = true; };
    ai.enable = lib.mkEnableOption "AI coding tools" // { default = true; };
    apps.enable = lib.mkEnableOption "GUI applications" // { default = true; };
  };

  config.programs.home-manager.enable = true;
}
