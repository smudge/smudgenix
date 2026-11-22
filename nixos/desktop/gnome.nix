{ config, lib, pkgs, ... }:

lib.mkIf config.smudgenix.desktop.gnome.enable {
  # Enable X11 for compatibility reasons:
  services.xserver.enable = true;
  services.xserver.excludePackages = [ pkgs.xterm ];

  # Enable the GNOME Desktop Environment (w/o core utils)
  services.desktopManager.gnome.enable = true;
  services.gnome.core-apps.enable = false;
  environment.gnome.excludePackages = [ pkgs.gnome-tour ];

  environment.systemPackages = with pkgs; [
    gnome-themes-extra
    adwaita-icon-theme
    papers

    gnomeExtensions.appindicator # tray icons
  ];
}
