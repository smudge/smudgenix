# The graphical desktop: sessions (GNOME and friends), the display manager,
# and machine-wide desktop defaults. Configured per-host via
# `smudgenix.desktop.*` and `smudgenix.apps.*`.
{ config, lib, pkgs, ... }:

let
  inherit (config.smudgenix) apps desktop;
in
{
  imports = [
    ./gnome.nix
  ];

  options.smudgenix = {
    desktop = {
      gnome.enable = lib.mkEnableOption "the GNOME desktop session" // { default = true; };

      keyRepeat = {
        delay = lib.mkOption {
          type = lib.types.ints.positive;
          default = 200;
          description = "Milliseconds a key is held before it starts repeating.";
        };
        rate = lib.mkOption {
          type = lib.types.ints.positive;
          default = 40;
          description = "Key repeats per second.";
        };
      };
    };

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

    # Machine-wide defaults for GTK apps & GNOME. Users can still change them
    # (in GNOME Settings, or via home-manager's `dconf.settings`).
    programs.dconf.enable = true;
    programs.dconf.profiles.user.databases = [{
      settings = {
        "org/gnome/desktop/interface" = {
          color-scheme = "prefer-dark";
          gtk-theme = "Adwaita-dark";
        };
        "org/gnome/desktop/peripherals/keyboard" = {
          delay = lib.gvariant.mkUint32 desktop.keyRepeat.delay;
          repeat-interval = lib.gvariant.mkUint32 (1000 / desktop.keyRepeat.rate);
        };
      };
    }];

    # Use libsecret and launch gnome-keyring at startup.
    programs.seahorse.enable = true;
    services.gnome.gnome-keyring.enable = true;
    security.pam.services.gdm.enableGnomeKeyring = true;

    # GTK themes, libsecret & the default desktop apps:
    environment.systemPackages = [
      pkgs.gnome-themes-extra # Adwaita-dark for GTK3
      pkgs.adwaita-icon-theme
      pkgs.libsecret
      apps.browser
      apps.terminal
      apps.fileManager
      apps.imageViewer
    ];
  };
}
