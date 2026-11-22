# Noctalia, the desktop shell (bar, launcher, notifications, OSDs, lock
# screen, idle, polkit agent, ...) for tiling sessions. It runs only inside
# niri, from a read-only config dir generated (and validated) here. Settings
# changed in its GUI are kept per-user in ~/.local/state/noctalia.
{ config, lib, pkgs, ... }:

let
  inherit (config.smudgenix) desktop;
  cfg = desktop.noctalia;
  format = pkgs.formats.toml { };
  noctalia = config.programs.noctalia.package;

  msg = args: { action = "spawn ${lib.concatMapStringsSep " " builtins.toJSON ([ "noctalia" "msg" ] ++ args)}"; };

  defaults = {
    shell = {
      offline_mode = true; # no weather, exchange rates, community palettes, ...
      polkit_agent = true;
    };

    theme = {
      mode = "dark";
      templates.enable_community_templates = false;
    };

    wallpaper = {
      transition = [ "fade" ];
      transition_duration = 600;
    };

    lockscreen.transition = [ "fade" ];

    idle.behavior = {
      lock = { enabled = true; timeout = 600; };
      screen-off = { enabled = true; timeout = 900; };
    };

    bar.main = {
      start = [ "workspaces" ];
      center = [ "clock" ];
      end = [ "tray" "notifications" "network" "bluetooth" "volume" "brightness" "battery" "control-center" "session" ];
    };
  };

  configDir = pkgs.runCommand "noctalia-config" { } ''
    mkdir -p $out
    cp ${format.generate "config.toml" cfg.settings} $out/config.toml
    # Unknown or mistyped settings are only warnings to Noctalia; fail on them.
    report=$(HOME=$TMPDIR NOCTALIA_CONFIG_HOME=$out ${lib.getExe noctalia} config validate $out/config.toml 2>&1)
    echo "$report"
    ! grep -qE '^(WARN|ERROR)' <<< "$report"
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

  config = lib.mkIf cfg.enable {
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
  };
}
