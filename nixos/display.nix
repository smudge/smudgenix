{ config, lib, ... }:

{
  options.smudgenix.hiDPI = lib.mkEnableOption "2x scaling for a high-DPI primary display";

  config = lib.mkMerge [
    {
      hardware.graphics.enable = true;
    }

    (lib.mkIf config.smudgenix.hiDPI {
      boot.loader.grub.fontSize = 60;

      environment.variables = {
        GDK_SCALE = "2";
        GDK_DPI_SCALE = "1";
        QT_SCALE_FACTOR = "0.5";
        PLASMA_USE_QT_SCALING = "1";
        _JAVA_OPTIONS = "-Dsun.java2d.uiScale=2";
      };
    })
  ];
}
