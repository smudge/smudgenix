{ config, lib, pkgs, ... }:

lib.mkIf config.smudgenix.desktop.gnome.enable {
  # Enable the GNOME Desktop Environment (w/o core utils)
  services.desktopManager.gnome.enable = true;
  services.gnome.core-apps.enable = false;
  environment.gnome.excludePackages = [ pkgs.gnome-tour ];

  environment.systemPackages = with pkgs; [
    papers

    gnomeExtensions.appindicator # tray icons
  ];
}
