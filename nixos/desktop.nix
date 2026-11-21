{ vars ? {} }:
{ config, pkgs, ... }: let
  v = {
  } // vars;
in {
  # Hint to electron apps that they should use Wayland
  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  # Symbol glyphs (powerline/nerd-font) for terminal UIs:
  fonts.packages = with pkgs; [
    powerline-fonts
    powerline-symbols
    nerd-fonts.symbols-only
  ];

  # Enable X11 for compatibility reasons:
  services.xserver.enable = true;
  services.xserver.xkb.layout = "us";
  services.xserver.xkb.variant = "";
  services.xserver.excludePackages = [ pkgs.xterm ];

  # Enable the GNOME Desktop Environment (w/o core utils)
  services.desktopManager.gnome.enable = true;
  services.gnome.core-apps.enable = false;
  environment.gnome.excludePackages = [ pkgs.gnome-tour ];

  environment.systemPackages = with pkgs; [
    gnome-themes-extra
    adwaita-icon-theme
    papers

    wl-clipboard
    xclip

    gnomeExtensions.appindicator # tray icons
  ];
}
