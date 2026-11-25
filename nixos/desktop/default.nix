# The graphical desktop: niri with the Noctalia shell (and its greeter), the
# default apps, and machine-wide desktop defaults. Configured per-host via
# `smudgenix.desktop.*` and `smudgenix.apps.*`.
{ config, lib, pkgs, ... }:

let
  theme = import ../../theme pkgs;
  removed = name: lib.mkRemovedOptionModule [ "smudgenix" "desktop" name ]
    "smudgenix no longer includes GNOME; niri (`smudgenix.desktop.niri`) is the desktop.";
in
{
  imports = [
    ./apps.nix
    ./binds.nix
    ./firefox.nix
    ./leader.nix
    ./niri.nix
    ./noctalia.nix
    (removed "gnome")
    (removed "defaultSession")
  ];

  options.smudgenix.desktop.keyRepeat = {
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

  options.smudgenix.desktop.touchpad.tapToClick = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Click by tapping the touchpad. Off by default, so a click takes
      pressing it down.
    '';
  };

  config = lib.mkIf config.smudgenix.desktop.niri.enable {
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

    # Machine-wide defaults for GTK apps (which read them from dconf, or via
    # the desktop portal). Users can still change them, via home-manager's
    # `dconf.settings`.
    programs.dconf.enable = true;
    programs.dconf.profiles.user.databases = [{
      settings."org/gnome/desktop/interface" = {
        color-scheme = "prefer-dark";
        gtk-theme = "Adwaita-dark";
        accent-color = "orange"; # the closest to smudge's ember
        font-name = "${theme.fonts.sans.name} 11";
        document-font-name = "${theme.fonts.sans.name} 11";
        monospace-font-name = "${theme.fonts.mono.name} 11";
      };
    }];

    # Secrets (saved passwords & keys, for libsecret apps) in oo7, unlocked
    # with the login password.
    #
    # Coming from gnome-keyring: on the first password login, oo7 converts
    # ~/.local/share/keyrings/login.keyring into its own format (in v1/),
    # and marks the original `.migrated`. That takes the keyring's password
    # to match the login password. Once everything's there, the old files can
    # go.
    #
    # It only unlocks at login, so restarting oo7-daemon locks it until the
    # next login.
    services.oo7.enable = true;
    # A fingerprint can't unlock it, so logging in takes the password. (The
    # lock screen reads fingerprints itself; see ./noctalia.nix.)
    security.pam.services.login.fprintAuth = false;
    services.gnome.gnome-keyring.enable = false;
    xdg.portal.config.niri."org.freedesktop.impl.portal.Secret" = lib.mkForce "oo7-portal";

    # And an SSH agent.
    programs.ssh.startAgent = true;

    # GTK themes & libsecret:
    environment.systemPackages = [
      pkgs.gnome-themes-extra # Adwaita-dark for GTK3
      pkgs.adwaita-icon-theme
      pkgs.libsecret
    ];
  };
}
