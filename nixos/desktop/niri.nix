# niri, a scrollable-tiling Wayland compositor. Its config is generated here
# (and validated at build time) and read from /etc/niri/config.kdl, never
# from ~/.config/niri.
{ config, lib, pkgs, ... }:

let
  inherit (config.smudgenix) apps desktop;
  cfg = desktop.niri;
  theme = import ../../theme pkgs;
  filePickerId = "smudgenix.filepicker";

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
            // Two-finger click to right-click, rather than the bottom-right
            // corner (as GNOME does). Touchpads with buttons keep them.
            click-method "clickfinger"
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
            active-color "${theme.accent}"
            inactive-color "${theme.colors.base02}"
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

    overview {
        backdrop-color "${theme.colors.base00}"
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

    window-rule {
        match app-id=r#"^${lib.escapeRegex filePickerId}$"#
        open-floating true
        default-column-width { proportion 0.6; }
        default-window-height { proportion 0.7; }
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

  config = lib.mkMerge [ (lib.mkIf cfg.enable {
    programs.niri = {
      enable = true;
      # (With `apps.filePicker = "gtk"`) use the GTK file chooser, rather
      # than pulling in Nautilus.
      useNautilus = false;
    };

    environment.etc."niri/config.kdl".source = validatedConfig;
    environment.sessionVariables.NIRI_CONFIG = "/etc/niri/config.kdl";

    environment.systemPackages = with pkgs; [
      xwayland-satellite # X11 apps (niri starts it on demand)
      brightnessctl
      playerctl
      bluetui # bluetooth & audio, in the terminal
      wiremix
    ];

    # GNOME enables IBus (input methods), whose autostart entry runs it
    # outside GNOME too, where it just warns that it should be started by
    # the compositor. niri doesn't need it, so skip it there.
    systemd.user.units."app-ibus\\x2ddaemon@autostart.service" = {
      overrideStrategy = "asDropin";
      text = "[Unit]\nConditionEnvironment=!XDG_CURRENT_DESKTOP=niri\n";
    };
  })

  (lib.mkIf (cfg.enable && apps.filePicker == "yazi") {
    # Choose files with yazi, in a (floating) terminal. GTK apps & Firefox
    # only ask the portal when GTK_USE_PORTAL is set, so set it for niri
    # sessions (niri-session passes the login shell's environment on).
    xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-termfilechooser ];
    xdg.portal.config.niri."org.freedesktop.impl.portal.FileChooser" = lib.mkForce "termfilechooser";
    environment.extraInit = ''
      if [ "''${XDG_CURRENT_DESKTOP:-}" = niri ]; then export GTK_USE_PORTAL=1; fi
    '';
    systemd.user.services.xdg-desktop-portal-termfilechooser = {
      path = [ pkgs.yazi pkgs.xdg-terminal-exec apps.terminal ];
      environment.TERMCMD =
        if lib.getName apps.terminal == "alacritty"
        then "${lib.getExe apps.terminal} --class ${filePickerId} -e"
        else "xdg-terminal-exec --app-id=${filePickerId}";
    };
  }) ];
}
