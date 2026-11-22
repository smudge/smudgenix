{ config, lib, pkgs, ... }:

let
  theme = import ../theme pkgs;
  inherit (theme.fonts) mono;
  size = if config.smudgenix.hiDPI then 32 else 16;

  # Converted here once (it warns about every ligature), not by each install.
  grubFont = pkgs.runCommand "${lib.toLower mono.name}-${toString size}.pf2" { } ''
    ${pkgs.grub2}/bin/grub-mkfont -s ${toString size} -o $out \
      ${mono.package}/share/fonts/opentype/${mono.name}-Regular.otf 2>/dev/null
  '';
in
{
  # Wayland compositors scale apps themselves (including X11 apps, via
  # Xwayland), so this only covers what runs before one starts.
  options.smudgenix.hiDPI = lib.mkEnableOption "larger boot menu and text console fonts, for a high-DPI primary display";

  config = {
    hardware.graphics.enable = true;

    # The boot menu, in smudge's monospace font: at the display's own
    # resolution (firmware offers few others), so twice as large on hiDPI.
    boot.loader.grub.font = lib.mkDefault "${grubFont}";

    # The text console, set up early (in the initrd), since once a graphical
    # login has taken over the first console, a font can't be set on the
    # rest.
    console = lib.mkIf config.smudgenix.hiDPI {
      earlySetup = lib.mkDefault true;
      font = lib.mkDefault "${pkgs.terminus_font}/share/consolefonts/ter-v32n.psf.gz";
    };
  };
}
