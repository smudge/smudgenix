{ config, pkgs, lib, ... }:

lib.mkIf config.smudgenix.ai.enable {
  home.packages = with pkgs; [
    claude-code
    # (Using the OS's server, where it has one; see ../../ai/opencode.sh.)
    (import ../../ai/opencode.nix pkgs)
  ];

  # Claude Code's personal (uncommitted) project settings.
  programs.git.ignores = [ ".claude/settings.local.json" ];
}
