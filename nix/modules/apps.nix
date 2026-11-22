{ config, pkgs, lib, ... }:

lib.mkIf config.smudgenix.apps.enable {
  home.packages = with pkgs; [
    hasklig
    discord
    obsidian
  ];

  # (Colors & font family come from ./theme.nix.) Super belongs to the window
  # manager and Ctrl/Alt to tmux (./tmux.nix); alacritty's own defaults cover
  # the rest (Ctrl+Shift+C/V, Ctrl+=/-/0).
  programs.alacritty = {
    enable = true;
    settings = let
      # Most terminals can't tell Ctrl+Shift+<letter> from Ctrl+<letter>, so
      # send Ctrl+Shift+hjkl as Alt+Shift+arrows (tmux: move the pane).
      esc = builtins.fromJSON ''"\u001b"'';
      altShiftArrow = key: arrow: { inherit key; mods = "Control|Shift"; chars = "${esc}[1;4${arrow}"; };
    in {
      keyboard.bindings = [
        (altShiftArrow "H" "D")
        (altShiftArrow "J" "B")
        (altShiftArrow "K" "A")
        (altShiftArrow "L" "C")
      ];
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
