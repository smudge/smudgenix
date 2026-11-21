{ config, pkgs, lib, ... }:

lib.mkIf config.smudgenix.ai.enable {
  home.packages = with pkgs; [
    claude-code
    opencode
  ];

  # Claude Code's personal (uncommitted) project settings.
  programs.git.ignores = [ ".claude/settings.local.json" ];
}
