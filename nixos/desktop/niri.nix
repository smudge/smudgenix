# niri, a scrollable-tiling Wayland compositor. Its config is generated here
# (and validated at build time) and read from /etc/niri/config.kdl, never
# from ~/.config/niri.
{ config, lib, pkgs, ... }:

let
  inherit (config.smudgenix) desktop;
  cfg = desktop.niri;

  kdlValue = v:
    if lib.isBool v then lib.boolToString v
    else if lib.isInt v then toString v
    else builtins.toJSON v;

  bind = key: value: let
    b = if lib.isString value then { action = value; } else value;
    opts = lib.mapAttrsToList (k: v: " ${k}=${kdlValue v}") (removeAttrs b [ "action" ]);
  in "    ${key}${lib.concatStrings opts} { ${b.action}; }";

  binds = lib.concatStringsSep "\n"
    (lib.mapAttrsToList bind (lib.filterAttrs (_: v: v != null) desktop.binds));

  configFile = pkgs.writeText "niri-config.kdl" ''
    input {
        keyboard {
            repeat-delay ${toString desktop.keyRepeat.delay}
            repeat-rate ${toString desktop.keyRepeat.rate}
        }
        touchpad {
            tap
            natural-scroll
        }
    }

    layout {
        gaps 12
        center-focused-column "never"
        preset-column-widths {
            proportion 0.33333
            proportion 0.5
            proportion 0.66667
        }
        default-column-width { proportion 0.5; }
        focus-ring {
            width 2
            active-color "#c8c9cc"
            inactive-color "#3a3c40"
        }
        border {
            off
        }
        shadow {
            on
            softness 30
            spread 5
            offset x=0 y=5
            color "#0007"
        }
    }

    // Let niri draw window decorations, rather than each app.
    prefer-no-csd

    hotkey-overlay {
        skip-at-startup
    }

    screenshot-path "~/Pictures/Screenshots/Screenshot from %Y-%m-%d %H-%M-%S.png"

    window-rule {
        geometry-corner-radius 8
        clip-to-geometry true
    }

    window-rule {
        match app-id=r#"firefox$"# title="^Picture-in-Picture$"
        open-floating true
    }

    binds {
    ${binds}
    }
    ${cfg.extraConfig}
  '';

  validatedConfig = pkgs.runCommand "niri-config.kdl" { } ''
    ${lib.getExe config.programs.niri.package} validate -c ${configFile}
    cp ${configFile} $out
  '';
in
{
  options.smudgenix.desktop.niri = {
    enable = lib.mkEnableOption "the niri (scrollable-tiling) desktop session";
    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Extra niri config (KDL), appended to the generated config. Sections
        smudgenix already sets (e.g. `layout`) can't be repeated here.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    programs.niri = {
      enable = true;
      # Use the GTK file chooser rather than pulling in Nautilus.
      useNautilus = false;
    };

    environment.etc."niri/config.kdl".source = validatedConfig;
    environment.sessionVariables.NIRI_CONFIG = "/etc/niri/config.kdl";

    environment.systemPackages = with pkgs; [
      xwayland-satellite # X11 apps (niri starts it on demand)
      brightnessctl
      playerctl
    ];
  };
}
