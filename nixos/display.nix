{ config, lib, ... }:

{
  # Wayland compositors scale apps themselves (including X11 apps, via
  # Xwayland), so this only covers what runs before one starts.
  options.smudgenix.hiDPI = lib.mkEnableOption "a larger boot menu font for a high-DPI primary display";

  config = lib.mkMerge [
    {
      hardware.graphics.enable = true;
    }

    (lib.mkIf config.smudgenix.hiDPI {
      boot.loader.grub.fontSize = 60;
    })
  ];
}
