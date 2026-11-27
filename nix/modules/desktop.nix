# Your own desktop settings, over the OS's (where its desktop is smudgenix's
# niri): written to ~/.config/niri/smudgenix.kdl, which the OS's niri config
# reads last. Anything left unset is the OS's. Your binds are on Super's
# shortcuts too (~/.config/smudgenix/shortcuts.json, over the OS's), and
# your pills' icons (smudgenix.desktop.noctalia.settings).
{ config, pkgs, lib, ... }:

let
  cfg = config.smudgenix.desktop;
  kdl = import ../../nixos/desktop/niri-kdl.nix { inherit lib; };
  shortcuts = import ../../nixos/desktop/shortcuts.nix { inherit lib; };
  inherit (cfg.noctalia) settings;
  # (Only the icons you've given, over the OS's, but any your binds open.)
  glyphs = shortcuts.glyphsOf { inherit settings; defaults = false; };
  sheet = shortcuts.sheet { inherit (cfg) binds; glyphs = shortcuts.glyphsOf { inherit settings; }; }
    // { inherit glyphs; };

  repeat = lib.filterAttrs (_: v: v != null) cfg.keyRepeat;

  input = lib.optional (repeat != { }) (kdl.keyboard repeat)
    ++ lib.optional (cfg.touchpad.tapToClick != null) (kdl.touchpad { tap = cfg.touchpad.tapToClick; });

  file = pkgs.writeText "smudgenix.kdl" (lib.concatStringsSep "\n\n" ([
    "// Written by home-manager, from your home flake's smudgenix.desktop.*."
  ] ++ lib.optional (input != [ ]) ''
    input {
        ${kdl.nested (lib.concatStringsSep "\n" input)}
    }''
    ++ lib.optional (cfg.binds != { }) (kdl.binds cfg.binds)
    ++ lib.optional (cfg.niri.extraConfig != "") cfg.niri.extraConfig
  ) + "\n");

  validated = pkgs.runCommand "smudgenix.kdl" { } ''
    ${lib.getExe pkgs.niri} validate -c ${file}
    cp ${file} $out
  '';

  anything = repeat != { } || cfg.touchpad.tapToClick != null || cfg.binds != { } || cfg.niri.extraConfig != "";
in
{
  options.smudgenix.desktop = {
    keyRepeat = {
      delay = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Milliseconds a key is held before it starts repeating (unset: the OS's).";
      };
      rate = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Key repeats per second (unset: the OS's).";
      };
    };
    touchpad.tapToClick = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = ''
        Click by tapping the touchpad, rather than pressing it down (unset:
        the OS's). Setting it also sets the rest of the touchpad's settings
        to smudgenix's (niri replaces a touchpad section as a whole).
      '';
    };
    binds = lib.mkOption {
      type = lib.types.attrsOf kdl.bindType;
      default = { };
      example = { "Mod+T" = ''spawn "alacritty"''; };
      description = ''
        Keybinds to add, or to replace the OS's with, as niri actions.
        (They can't remove the OS's binds.)
      '';
    };
    niri.extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra niri config (KDL), over the OS's.";
    };
  };

  config = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    xdg.configFile."niri/smudgenix.kdl" = lib.mkIf anything { source = validated; };
    xdg.configFile."smudgenix/shortcuts.json" = lib.mkIf (cfg.binds != { } || glyphs != { }) {
      text = builtins.toJSON sheet;
    };
  };
}
