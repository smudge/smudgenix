# The smudge theme (../../theme) for terminal tools. The desktop itself is
# themed system-side.
{ config, pkgs, lib, ... }:

let
  theme = import ../../theme pkgs;
  c = theme.colors;
in
{
  programs.nixvim.colorschemes.base16 = {
    enable = true;
    colorscheme = lib.filterAttrs (name: _: lib.hasPrefix "base" name) c;
  };

  # bat follows the terminal's (smudge) ANSI colors.
  home.sessionVariables.BAT_THEME = "ansi";

  home.sessionVariables.FZF_DEFAULT_OPTS = lib.concatStringsSep "," [
    "--color=bg:-1" "bg+:${c.base01}" "fg:${c.base04}" "fg+:${c.base06}"
    "hl:${theme.accent}" "hl+:${theme.accent}" "info:${c.base03}"
    "prompt:${theme.accent}" "pointer:${theme.accent}" "marker:${theme.accent}"
    "spinner:${c.base03}" "header:${c.base04}" "border:${c.base02}"
  ];

  programs.tmux.extraConfig = ''
    set -g pane-border-style "fg=${c.base02}"
    set -g pane-active-border-style "fg=${theme.accent}"
    set -g mode-style "fg=${c.base06},bg=${c.base02}"
    set -g message-style "fg=${c.base05},bg=${c.base01}"
  '';

  programs.alacritty = lib.mkIf config.smudgenix.apps.enable {
    settings = {
      font.normal.family = theme.fonts.mono.name;
      colors = {
        primary = { inherit (theme.terminal) background foreground; };
        cursor = { text = c.base00; cursor = c.base05; };
        selection = { text = c.base06; background = c.base02; };
        inherit (theme.terminal) normal bright;
      };
    };
  };
}
