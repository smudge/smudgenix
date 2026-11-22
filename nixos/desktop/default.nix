# The graphical desktop: sessions (GNOME and friends), the display manager,
# and machine-wide desktop defaults. Configured per-host via
# `smudgenix.desktop.*` and `smudgenix.apps.*`.
{ config, lib, pkgs, ... }:

let
  inherit (config.smudgenix) apps desktop;
  theme = import ../../theme pkgs;
in
{
  imports = [
    ./binds.nix
    ./gnome.nix
    ./niri.nix
    ./noctalia.nix
  ];

  options.smudgenix = {
    desktop = {
      gnome.enable = lib.mkEnableOption "the GNOME desktop session" // { default = true; };

      defaultSession = lib.mkOption {
        type = lib.types.enum [ "gnome" "niri" ];
        default = if desktop.gnome.enable then "gnome" else "niri";
        defaultText = lib.literalExpression ''if gnome.enable then "gnome" else "niri"'';
        description = "Session preselected at login (users can still pick another).";
      };

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
    assertions = [{
      assertion = desktop.${desktop.defaultSession}.enable;
      message = "smudgenix: `desktop.defaultSession` (\"${desktop.defaultSession}\") must be enabled.";
    }];

    services.displayManager.defaultSession = desktop.defaultSession;
    services.displayManager.gdm.enable = true;

    # Hint to electron apps that they should use Wayland
    environment.sessionVariables.NIXOS_OZONE_WL = "1";

    # The theme's fonts, and symbol glyphs (powerline/nerd-font) for
    # terminal UIs:
    fonts.packages = with pkgs; [
      theme.fonts.sans.package
      theme.fonts.mono.package
      powerline-fonts
      powerline-symbols
      nerd-fonts.symbols-only
    ];
    fonts.fontconfig.defaultFonts = {
      sansSerif = [ theme.fonts.sans.name ];
      monospace = [ theme.fonts.mono.name ];
    };

    # Machine-wide defaults for GTK apps & GNOME. Users can still change them
    # (in GNOME Settings, or via home-manager's `dconf.settings`).
    programs.dconf.enable = true;
    programs.dconf.profiles.user.databases = [{
      settings = {
        "org/gnome/desktop/interface" = {
          color-scheme = "prefer-dark";
          gtk-theme = "Adwaita-dark";
          accent-color = "orange"; # the closest to smudge's ember
          font-name = "${theme.fonts.sans.name} 11";
          document-font-name = "${theme.fonts.sans.name} 11";
          monospace-font-name = "${theme.fonts.mono.name} 11";
        };
        "org/gnome/desktop/peripherals/keyboard" = {
          delay = lib.gvariant.mkUint32 desktop.keyRepeat.delay;
          repeat-interval = lib.gvariant.mkUint32 (1000 / desktop.keyRepeat.rate);
        };
      };
    }];

    # Use libsecret and launch gnome-keyring at startup.
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
