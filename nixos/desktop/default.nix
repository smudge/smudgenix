# The graphical desktop: sessions (GNOME and friends), the display manager,
# and machine-wide desktop defaults. Configured per-host via
# `smudgenix.desktop.*` and `smudgenix.apps.*`.
{ config, lib, pkgs, ... }:

let
  apps = config.smudgenix.apps;
in
{
  imports = [
    ./gnome.nix
  ];

  options.smudgenix = {
    desktop.gnome.enable = lib.mkEnableOption "the GNOME desktop session" // { default = true; };

    apps = {
      browser = lib.mkPackageOption pkgs "firefox" { };
      terminal = lib.mkPackageOption pkgs "alacritty" { };
      fileManager = lib.mkPackageOption pkgs "nemo" { };
      imageViewer = lib.mkPackageOption pkgs "eog" { };
    };
  };

  config = {
    services.displayManager.gdm.enable = true;

    # Hint to electron apps that they should use Wayland
    environment.sessionVariables.NIXOS_OZONE_WL = "1";

    # Symbol glyphs (powerline/nerd-font) for terminal UIs:
    fonts.packages = with pkgs; [
      powerline-fonts
      powerline-symbols
      nerd-fonts.symbols-only
    ];

    # Use libsecret and launch gnome-keyring at startup.
    programs.dconf.enable = true;
    programs.seahorse.enable = true;
    services.gnome.gnome-keyring.enable = true;
    security.pam.services.gdm.enableGnomeKeyring = true;

    # Default desktop apps:
    environment.systemPackages = [
      pkgs.libsecret
      apps.browser
      apps.terminal
      apps.fileManager
      apps.imageViewer
    ];
  };
}
