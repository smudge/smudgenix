{ config, pkgs, lib, ... }:

lib.mkIf config.smudgenix.dev.enable {
  home.packages = with pkgs; [
    nodejs
    yarn
    rustup
  ];
}
