{ config, pkgs, lib, ... }:

lib.mkIf config.smudgenix.apps.enable {
  home.packages = with pkgs; [
    hasklig
    firefox
    discord
    obsidian
  ];

  # (Colors & font family come from ./theme.nix.)
  programs.alacritty = {
    enable = true;
    settings = let
      # Send tmux's prefix (C-b) and then a key.
      prefix = builtins.fromJSON ''"\u0002"'';
      tmux = key: mods: chars: { inherit key mods; chars = prefix + chars; };
    in {
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
      keyboard.bindings = [
        (tmux "T" "Command" "c")         # new window
        (tmux "D" "Command" "%")         # split side-by-side
        (tmux "D" "Command|Shift" "\"")   # split stacked
        (tmux "W" "Command" "x")         # close pane
        (tmux "H" "Command" "p")         # previous window
        (tmux "L" "Command" "n")         # next window
        (tmux "J" "Command" "J")
        (tmux "K" "Command" "K")
        (tmux "H" "Control|Shift" "h")   # move between panes
        (tmux "J" "Control|Shift" "j")
        (tmux "K" "Control|Shift" "k")
        (tmux "L" "Control|Shift" "l")
        { key = "Key0"; mods = "Command"; action = "ResetFontSize"; }
        { key = "Equals"; mods = "Command"; action = "IncreaseFontSize"; }
        { key = "Plus"; mods = "Command"; action = "IncreaseFontSize"; }
        { key = "Minus"; mods = "Command"; action = "DecreaseFontSize"; }
        { key = "V"; mods = "Command"; action = "Paste"; }
        { key = "C"; mods = "Command"; action = "Copy"; }
        { key = "Q"; mods = "Command"; action = "Quit"; }
        { key = "F"; mods = "Command|Control"; action = "ToggleFullscreen"; }
      ];
    };
  };

  # Obsidian's per-device window state, for vaults kept in git.
  programs.git.ignores = [ ".obsidian/workspace*.json" ];
}
