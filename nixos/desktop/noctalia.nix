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

  # (Agents on the bar, with the AI module: see ../ai.nix.)
  agents = config.smudgenix.ai.enable;

  # Super and the F-row opens the bar's other pills' pages, by the icon on the
  # key where there is one (and with Shift, a neighbour's). Each as the F key
  # and what it sends with Fn-lock off, on a Framework.
  pills = lib.foldl' (acc: p: acc // lib.listToAttrs (map (key: {
    name = "Mod+${key}";
    value = msg [ "panel-toggle" "control-center" p.page ] // { hotkey-overlay-title = p.title; };
  }) p.keys)) { } [
    { page = "audio"; title = "Show Volume"; keys = [ "F1" "F2" "F3" "XF86AudioMute" "XF86AudioLowerVolume" "XF86AudioRaiseVolume" ]; }
    { page = "media"; title = "Show Media"; keys = [ "F4" "F5" "F6" "XF86AudioPrev" "XF86AudioPlay" "XF86AudioNext" ]; }
    { page = "monitor"; title = "Show Brightness"; keys = [ "F7" "F8" "XF86MonBrightnessDown" "XF86MonBrightnessUp" ]; }
    { page = "power"; title = "Show Battery"; keys = [ "Shift+F7" "Shift+F8" "Shift+XF86MonBrightnessDown" "Shift+XF86MonBrightnessUp" ]; }
    { page = "network"; title = "Show Network"; keys = [ "F10" "XF86RFKill" ]; }
    { page = "bluetooth"; title = "Show Bluetooth"; keys = [ "Shift+F10" "Shift+XF86RFKill" ]; }
    { page = "calendar"; title = "Show Calendar"; keys = [ "F11" "Print" ]; }
    { page = "notifications"; title = "Show Notifications"; keys = [ "F12" "XF86AudioMedia" ]; }
  ];

  # smudgenix's own plugins (../../noctalia/plugins), checked the way Noctalia
  # loads them. (A home can use a checkout's instead, as you edit them: see
  # ../../nix/modules/noctalia.nix.)
  plugins = pkgs.runCommand "smudgenix-noctalia-plugins" { } ''
    cp -r ${../../noctalia/plugins} $out
    HOME=$TMPDIR ${lib.getExe noctalia} plugins lint $out
  '';

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
      # Panels drop from the bar, which shows while they're open.
      panel = { launcher_placement = "attached"; clipboard_placement = "attached"; };
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
      transition_duration = 500;
      # Unlock with a fingerprint, where there's a reader. (Noctalia reads it
      # itself, not via PAM: the login PAM service is password-only.)
      fingerprint = config.services.fprintd.enable;
    };

    idle.behavior = {
      lock = { enabled = true; timeout = 600; };
      screen-off = { enabled = true; timeout = 900; };
    };

    # Warmer, dimmer evenings. (Offline, so the day's times are fixed; hosts
    # elsewhere can set their own `location.sunrise`/`sunset`.)
    nightlight.enabled = true;
    brightness.enable_scheduled_brightness = true;
    location = { custom_schedule = true; sunrise = "06:00"; sunset = "20:30"; };

    weather.enabled = false;
    desktop_widgets.enabled = false;

    # Noctalia's plugin sources, and smudgenix's (read-only, from the store).
    plugins = {
      source = [
        { name = "official"; kind = "git"; location = "https://github.com/noctalia-dev/official-plugins"; enabled = true; }
        { name = "community"; kind = "git"; location = "https://github.com/noctalia-dev/community-plugins"; enabled = true; }
        { name = "smudgenix"; kind = "path"; location = "${plugins}"; enabled = true; }
      ];
      enabled = lib.optional agents "smudgenix/agents"
        ++ lib.optional desktop.leader.enable "smudgenix/shortcuts";
    };

    # (Only when it isn't the plugin's default.)
    plugin_settings = lib.optionalAttrs (agents && !config.smudgenix.ai.notify) {
      "smudgenix/agents".notify = false;
    };

    # A dock, out of the way until it's needed.
    dock = {
      enabled = true;
      smart_auto_hide = true;
      reserve_space = false;
    };

    # A wide control center, without its sidebar.
    control_center = {
      width = 1000;
      sidebar = "none";
      sidebar_section = "none";
      hidden_tabs = [ "calendar" "weather" "screen-time" ];
      calendar.show_events_card = false;
      media.show_visualizer = false;
    };

    # A thin bar along the top edge, with rounded ends and widgets grouped in
    # capsules. It hides itself when a window needs the space.
    bar.default = {
      thickness = 28;
      margin_edge = 0;
      margin_ends = "1%";
      shadow = false;
      compositor_blur = false;
      capsule = true;
      layer = "auto";
      smart_auto_hide = true;
      reserve_space = false;
      start = [ "launcher" "workspaces" ] ++ lib.optional agents "agents" ++ [ "clipboard" "media" ];
      center = [ "clock" "control-center" ];
      end = [ "tray" "network" "bluetooth" "volume" "brightness" "battery" "notifications" "session" ];
    };

    # Icons only, and a short date & time.
    widget = {
      clock = { capsule = false; format = "{:%b %-d, %Y %I:%M%P}"; };
      battery = { display_mode = "graphic"; hide_when_full = true; show_label = false; };
      brightness.show_label = false;
      network.show_label = false;
      volume.show_label = false;
    } // lib.optionalAttrs agents {
      agents.type = "smudgenix/agents:agents";
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

    smudgenix.desktop.binds = lib.mapAttrs (_: lib.mkDefault) ({
      "Mod+Space" = msg [ "panel-toggle" "launcher" ] // { hotkey-overlay-title = "Open the Launcher"; };
      "Mod+Ctrl+V" = msg [ "panel-toggle" "clipboard" ] // { hotkey-overlay-title = "Show Clipboard History"; };
      "Mod+N" = msg [ "panel-toggle" "control-center" ] // { hotkey-overlay-title = "Open the Control Center"; };
      "Super+Alt+L" = msg [ "session" "lock" ] // { hotkey-overlay-title = "Lock the Screen"; };
    } // lib.optionalAttrs agents {
      "Mod+A" = msg [ "panel-toggle" "smudgenix/agents:sessions" ] // { hotkey-overlay-title = "Show Agents"; };
    } // pills) // {
      # (Over niri's quit prompt, ./binds.nix: the session menu has it.)
      "Mod+Shift+E" = lib.mkOverride 900
        (msg [ "panel-toggle" "session" ] // { hotkey-overlay-title = "Show the Session Menu"; });
    };
  }) ];
}
