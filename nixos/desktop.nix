{ vars ? {} }:
{ config, pkgs, ... }: let
  v = vars // {
  };
in {
  # Use hyprland:
  programs.hyprland.enable = true;
  environment.sessionVariables = {
    # Fix invisible cursors on Wayland
    WLR_NO_HARDWARE_CURSORS = "1";
    # Hint to electron apps that they should use Wayland
    NIXOS_OZONE_WL = "1";
  };
  xdg.portal = {
    xdgOpenUsePortal = true;
    enable = true;
    # wlr.enable = true;
    # lxqt.enable = true;
    extraPortals = [
        pkgs.xdg-desktop-portal-gtk
    #   pkgs.xdg-desktop-portal-gnome
    #   pkgs.xdg-desktop-portal-kde
    #   pkgs.xdg-desktop-portal-wlr
    ];
  };

  # For waybar:
  fonts.packages = with pkgs; [
    font-awesome
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

  # Packages for Hyprland and Waybar:
  environment.systemPackages = with pkgs; [
    networkmanagerapplet
    kitty
    font-awesome
    pavucontrol
    pulseaudio
    brightnessctl
    wlogout
    libinput-gestures
    gnome-themes-extra
    adwaita-icon-theme

    wl-clipboard
    xclip

    # Display workspaces correctly
    (waybar.overrideAttrs (oldAttrs: {
        mesonFlags = oldAttrs.mesonFlags ++ [ "-Dexperimental=true" ];
      })
      )

    # Missing GNOME features:
    # gnomeExtensions.x11-gestures # basic gestures
    # gnomeExtensions.gesture-improvements # better gestures
    # gnomeExtensions.desktop-icons-ng-ding # desktop icons
    # gnomeExtensions.appindicator # tray icons
  ];

}
