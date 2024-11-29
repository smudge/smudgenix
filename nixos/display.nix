{ vars ? {} }:
{ config, ... }: let
  v = vars // {
    hiDPI = false;
  };

  # High DPI adjustments for primary screen/monitor:
  hiDPIConfig = if vars.hiDPI then {
    boot.loader.grub.fontSize = 60;

    environment.variables = {
      GDK_SCALE = "2";
      GDK_DPI_SCALE = "1";
      QT_SCALE_FACTOR = "0.5";
      PLASMA_USE_QT_SCALING = "1";
      _JAVA_OPTIONS = "-Dsun.java2d.uiScale=2";
    };

  } else {};
in
{
  config = hiDPIConfig // {
    hardware.graphics.enable = true;
    services.xserver.displayManager.gdm.enable = true;
  };
}
