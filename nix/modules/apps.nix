{ config, pkgs, lib, ... }:

lib.mkIf config.smudgenix.apps.enable {
  home.packages = with pkgs; [
    hasklig
    firefox
    discord
    obsidian
  ];

  # (Colors & font family come from ./theme.nix.) No custom keybinds: Super
  # belongs to the window manager, Ctrl+hjkl to tmux/nvim, and alacritty's
  # defaults cover the rest (Ctrl+Shift+C/V, Ctrl+=/-/0).
  programs.alacritty = {
    enable = true;
    settings = {
      font = {
        size = 14;
        offset.x = -1;
      };
      colors.draw_bold_text_with_bright_colors = true;
      mouse.hide_when_typing = true;
      window = {
        title = "Terminal";
        padding = { x = 6; y = 4; };
      };
    };
  };

  # Obsidian's per-device window state, for vaults kept in git.
  programs.git.ignores = [ ".obsidian/workspace*.json" ];
}
