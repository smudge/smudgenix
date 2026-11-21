{ lib, ... }:

{
  imports = [
    ./cli.nix
    ./shell.nix
    ./tmux.nix
    ./nvim.nix
    ./theme.nix
    ./dev.nix
    ./ai.nix
    ./apps.nix
  ];

  options.smudgenix = {
    dev.enable = lib.mkEnableOption "development toolchains" // { default = true; };
    ai.enable = lib.mkEnableOption "AI coding tools" // { default = true; };
    apps.enable = lib.mkEnableOption "GUI applications" // { default = true; };
  };

  config.programs.home-manager.enable = true;
}
