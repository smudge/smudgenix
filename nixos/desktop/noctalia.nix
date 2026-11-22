# Noctalia, the desktop shell (bar, launcher, notifications, OSDs, lock
# screen, idle, polkit agent, ...) for tiling sessions. It runs only inside
# niri, from a read-only config dir generated (and validated) here. Settings
# changed in its GUI are kept per-user in ~/.local/state/noctalia. Also its
# greeter, the login screen (on greetd).
{ config, lib, pkgs, ... }:

let
  inherit (config.smudgenix) desktop;
  cfg = desktop.noctalia;
  format = pkgs.formats.toml { };
  noctalia = config.programs.noctalia.package;

  theme = import ../../theme pkgs;

  msg = args: { action = "spawn ${lib.concatMapStringsSep " " builtins.toJSON ([ "noctalia" "msg" ] ++ args)}"; };

  # The smudge theme as a Noctalia palette (dark only).
  palette = with theme.colors; {
    version = 2;
    base = "smudgenix";
    dark = {
      primary = theme.accent;
      on_primary = base00;
      secondary = base05;
      on_secondary = base00;
      tertiary = base0F;
      on_tertiary = base00;
      error = base08;
      on_error = base00;
      surface = base00;
      on_surface = base05;
      surface_container = base01;
      on_surface_variant = base04;
      outline_variant = base02;
      shadow = "#000000";
      hover = base02;
      on_hover = base06;
      terminal = theme.terminal // {
        cursor = base05;
        cursor_text = base00;
        selection_bg = base02;
        selection_fg = base06;
      };
    };
  };

  defaults = {
    shell = {
      offline_mode = true; # no weather, exchange rates, community palettes, ...
      polkit_agent = true;
      font_family = theme.fonts.sans.name;
      corner_radius_scale = 0.5;
      settings_show_advanced = false;
      launcher = {
        layout = "simple";
        show_app_origin_indicator = false;
        fetch_exchange_rates = false;
      };
    };

    theme = {
      mode = "dark";
      source = "custom";
      custom_palette = theme.name;
      templates.enable_community_templates = false;
    };

    wallpaper = {
      default.path = "${theme.wallpaper}";
      transition = [ "fade" ];
      transition_duration = 600;
    };

    lockscreen = {
      transition = [ "fade" ];
      # Unlock with a fingerprint, where there's a reader. (Noctalia reads it
      # itself, not via PAM: the login PAM service is password-only.)
      fingerprint = config.services.fprintd.enable;
    };

    idle.behavior = {
      lock = { enabled = true; timeout = 600; };
      screen-off = { enabled = true; timeout = 900; };
    };

    control_center = {
      hidden_tabs = [ "calendar" "weather" "screen-time" ];
      calendar.show_events_card = false;
      media.show_visualizer = false;
    };

    # A thin bar along the top edge, with widgets grouped in capsules. It
    # hides itself when a window needs the space.
    bar.default = {
      thickness = 28;
      radius = 0;
      margin_edge = 0;
      margin_ends = "1%";
      shadow = false;
      compositor_blur = false;
      capsule = true;
      layer = "auto";
      smart_auto_hide = true;
      reserve_space = false;
      start = [ "launcher" "wallpaper" "workspaces" "media" ];
      center = [ "clock" ];
      end = [ "tray" "network" "bluetooth" "volume" "brightness" "battery" "clipboard" "notifications" "control-center" "session" ];
    };

    # Icons only, and a short date & time.
    widget = {
      clock = { capsule = false; format = "{:%b %-d, %Y %I:%M%P}"; };
      battery = { display_mode = "graphic"; hide_when_full = true; show_label = false; };
      brightness.show_label = false;
      network.show_label = false;
      volume.show_label = false;
    };
  };

  # The login screen, in the same look. (All set here, so nothing syncs it
  # from the shell at runtime.)
  greeter = with palette.dark; {
    session.default = "niri";
    user.default = config.smudgenix.user.name;
    appearance = {
      scheme = "Synced";
      theme_mode = "dark";
      font_family = theme.fonts.sans.name;
      inherit (defaults.shell) corner_radius_scale;
      hide_logo = true;
      scheme_selector_position = "hidden";
      palette = {
        inherit primary on_primary secondary on_secondary tertiary on_tertiary error on_error;
        inherit surface on_surface on_surface_variant shadow hover on_hover;
        surface_variant = surface_container;
        outline = outline_variant;
      };
      wallpaper = { path = "${theme.wallpaper}"; fill_mode = "crop"; };
    };
    clock = { time_format = "%-I:%M"; date_format = "%A, %B %-d"; };
  };

  configDir = pkgs.runCommand "noctalia-config" { } ''
    # (Noctalia reads $NOCTALIA_CONFIG_HOME/noctalia/.)
    mkdir -p $out/noctalia/palettes
    cp ${format.generate "config.toml" cfg.settings} $out/noctalia/config.toml
    cp ${pkgs.writeText "palette.json" (builtins.toJSON palette)} $out/noctalia/palettes/${theme.name}.json

    # Check the config the way the shell loads it, failing on unknown or
    # mistyped settings (only warnings to Noctalia), and that it loads at all.
    export HOME=$TMPDIR NOCTALIA_CONFIG_HOME=$out
    report=$(${lib.getExe noctalia} config validate 2>&1)
    echo "$report"
    ! grep -qE '^(WARN|ERROR)' <<< "$report"
    ${lib.getExe noctalia} config export | grep -qF 'custom_palette = "${theme.name}"'
  '';
in
{
  options.smudgenix.desktop.noctalia = {
    enable = lib.mkEnableOption "the Noctalia desktop shell in tiling sessions" // {
      default = desktop.niri.enable;
      defaultText = lib.literalExpression "config.smudgenix.desktop.niri.enable";
    };
    settings = lib.mkOption {
      inherit (format) type;
      default = { };
      description = ''
        Noctalia settings (see https://docs.noctalia.dev/noctalia/), merged
        over smudgenix's defaults.
      '';
    };
  };

  config = lib.mkMerge [ (lib.mkIf desktop.niri.enable {
    services.displayManager.noctalia-greeter = {
      enable = true;
      settings = lib.mapAttrsRecursive (_: lib.mkDefault) greeter;
    };
  })

  (lib.mkIf cfg.enable {
    assertions = [{
      assertion = desktop.niri.enable;
      message = "smudgenix: `desktop.noctalia` needs `desktop.niri.enable`.";
    }];

    smudgenix.desktop.noctalia.settings = lib.mapAttrsRecursive (_: lib.mkDefault) defaults;

    programs.noctalia = {
      enable = true;
      systemd = {
        enable = true;
        target = "niri.service";
      };
      # NetworkManager & bluetooth (already on), UPower and power profiles.
      recommendedServices.enable = true;
    };

    systemd.user.services.noctalia.environment.NOCTALIA_CONFIG_HOME = "${configDir}";
    environment.sessionVariables.NOCTALIA_CONFIG_HOME = "${configDir}";

    smudgenix.desktop.binds = lib.mapAttrs (_: lib.mkDefault) {
      "Mod+Space" = msg [ "panel-toggle" "launcher" ] // { hotkey-overlay-title = "Open the Launcher"; };
      "Mod+Ctrl+V" = msg [ "panel-toggle" "clipboard" ] // { hotkey-overlay-title = "Show Clipboard History"; };
      "Mod+N" = msg [ "panel-toggle" "control-center" ];
      "Super+Alt+L" = msg [ "session" "lock" ] // { hotkey-overlay-title = "Lock the Screen"; };
    };
  }) ];
}
