{ config, pkgs, lib, ... }:

lib.mkIf config.smudgenix.apps.enable {
  home.packages = with pkgs; [
    hasklig
    firefox
    discord
    obsidian
  ];

  # Obsidian's per-device window state, for vaults kept in git.
  programs.git.ignores = [ ".obsidian/workspace*.json" ];
}
