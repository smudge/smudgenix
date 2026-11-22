# smudge: the smudgenix theme. A graphite ramp with one ember accent, plus
# muted ANSI colors, shared by the system (../nixos) and homes (../nix):
#
#   theme = import ../theme pkgs;
#
# Colors are base16 (https://github.com/tinted-theming/home), so most tools
# with a base16 template can use them as-is.
pkgs:

let
  colors = {
    # Graphite, darkest to lightest.
    base00 = "#141518"; # background
    base01 = "#1b1c20"; # raised surfaces, status lines
    base02 = "#26282c"; # selection, borders
    base03 = "#5f6269"; # comments, muted text
    base04 = "#8b8e94"; # secondary text
    base05 = "#c8c9cc"; # text
    base06 = "#dcdde0";
    base07 = "#e8e9eb"; # brightest text

    # Muted accents. base09 (ember) is *the* accent; the rest mostly stay in
    # terminals and code.
    base08 = "#c27272"; # red
    base09 = "#d08a4e"; # ember
    base0A = "#cbb072"; # yellow
    base0B = "#93ad82"; # green
    base0C = "#82abab"; # cyan
    base0D = "#8199b8"; # blue
    base0E = "#a58cab"; # magenta
    base0F = "#9c7a5e"; # brown
  };
in
{
  name = "smudge";

  inherit colors;
  accent = colors.base09;

  # ANSI terminal colors (0-7; the bright ones are the same, but lighter
  # black & white).
  terminal = with colors; {
    background = base00;
    foreground = base05;
    normal = {
      black = base02; red = base08; green = base0B; yellow = base0A;
      blue = base0D; magenta = base0E; cyan = base0C; white = base05;
    };
    bright = {
      black = base03; red = base08; green = base0B; yellow = base0A;
      blue = base0D; magenta = base0E; cyan = base0C; white = base07;
    };
  };

  fonts = {
    sans = { name = "Inter"; package = pkgs.inter; };
    mono = { name = "Hasklig"; package = pkgs.hasklig; };
  };

  wallpaper = pkgs.callPackage ./wallpaper.nix { inherit colors; };
}
