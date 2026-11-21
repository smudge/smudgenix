{ config, pkgs, lib, ... }:

lib.mkIf config.smudgenix.apps.enable {
  home.packages = with pkgs; [
    hasklig
    alacritty
    firefox
    discord
    obsidian
  ];
}
