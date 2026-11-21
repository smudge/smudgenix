{ config, pkgs, lib, ... }:

lib.mkIf config.smudgenix.ai.enable {
  home.packages = with pkgs; [
    claude-code
    opencode
  ];
}
