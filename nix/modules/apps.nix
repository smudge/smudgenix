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
    # (Its desktop entry, saying how it takes an app-id, so `xdg-terminal-exec
    # --app-id=…` sets one: niri's window rules match on it, e.g. smx ai's
    # sessions'. This profile's entry comes first, so it needs it too.)
    package = pkgs.symlinkJoin {
      name = "alacritty-${pkgs.alacritty.version}";
      paths = [ pkgs.alacritty ];
      postBuild = ''
        entry=$out/share/applications/Alacritty.desktop
        sed '/^\[Desktop Entry\]$/a X-TerminalArgAppId=--class=' "$(readlink -f "$entry")" > $entry.new
        rm "$entry"; mv $entry.new "$entry"
      '';
      inherit (pkgs.alacritty) meta;
    };
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
