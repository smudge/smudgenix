# Keybinds for tiling sessions, as `"Mods+Key" = action`. An action is a niri
# action string, or an attrset of { action; <bind options> } (e.g. repeat =
# false). Hosts can add binds, replace them, or drop one by setting it to null.
{ config, lib, ... }:

let
  inherit (config.smudgenix) apps;

  kdlStr = s: builtins.toJSON (toString s);
  spawn = args: "spawn ${lib.concatMapStringsSep " " kdlStr args}";
  spawnSh = cmd: "spawn-sh ${kdlStr cmd}";
  open = title: pkg: { action = spawn [ (lib.getExe pkg) ]; hotkey-overlay-title = title; };
  media = action: { inherit action; allow-when-locked = true; };

  # Mod+<n> / Mod+Ctrl+<n> for workspaces 1-9.
  workspaces = lib.listToAttrs (lib.concatMap (n: let i = toString n; in [
    { name = "Mod+${i}"; value = "focus-workspace ${i}"; }
    { name = "Mod+Ctrl+${i}"; value = "move-column-to-workspace ${i}"; }
  ]) (lib.range 1 9));

  # hjkl and the arrow keys, for focusing & moving in each direction.
  directions = lib.concatMapAttrs (dir: keys: lib.concatMapAttrs (_: key: {
    "Mod+${key}" = if dir == "left" || dir == "right" then "focus-column-${dir}" else "focus-window-${dir}";
    "Mod+Ctrl+${key}" = if dir == "left" || dir == "right" then "move-column-${dir}" else "move-window-${dir}";
    "Mod+Shift+${key}" = "focus-monitor-${dir}";
    "Mod+Shift+Ctrl+${key}" = "move-column-to-monitor-${dir}";
  }) keys) {
    left = { vi = "H"; arrow = "Left"; };
    down = { vi = "J"; arrow = "Down"; };
    up = { vi = "K"; arrow = "Up"; };
    right = { vi = "L"; arrow = "Right"; };
  };

  defaults = directions // workspaces // {
    "Mod+Shift+Slash" = "show-hotkey-overlay";

    # Apps
    "Mod+Return" = open "Open a Terminal" apps.terminal;
    # (tmux-snap comes from smudgenix's home config.)
    "Mod+Shift+Return" = {
      action = spawnSh "exec ${lib.getExe apps.terminal} -e sh -c 'command -v tmux-snap >/dev/null && exec tmux-snap reopen; exec \"$SHELL\"'";
      hotkey-overlay-title = "Reopen a Closed Terminal";
    };
    "Mod+B" = open "Open the Browser" apps.browser;
    "Mod+E" = open "Open the File Manager" apps.fileManager;

    # Windows & columns
    "Mod+Q" = { action = "close-window"; repeat = false; };
    "Mod+O" = { action = "toggle-overview"; repeat = false; };
    "Mod+Home" = "focus-column-first";
    "Mod+End" = "focus-column-last";
    "Mod+Ctrl+Home" = "move-column-to-first";
    "Mod+Ctrl+End" = "move-column-to-last";
    "Mod+BracketLeft" = "consume-or-expel-window-left";
    "Mod+BracketRight" = "consume-or-expel-window-right";
    "Mod+Comma" = "consume-window-into-column";
    "Mod+Period" = "expel-window-from-column";
    "Mod+R" = "switch-preset-column-width";
    "Mod+Shift+R" = "switch-preset-column-width-back";
    "Mod+Ctrl+Shift+R" = "switch-preset-window-height";
    "Mod+Ctrl+R" = "reset-window-height";
    "Mod+F" = "maximize-column";
    "Mod+Shift+F" = "fullscreen-window";
    "Mod+M" = "maximize-window-to-edges";
    "Mod+Ctrl+F" = "expand-column-to-available-width";
    "Mod+C" = "center-column";
    "Mod+Ctrl+C" = "center-visible-columns";
    "Mod+Minus" = ''set-column-width "-10%"'';
    "Mod+Equal" = ''set-column-width "+10%"'';
    "Mod+Shift+Minus" = ''set-window-height "-10%"'';
    "Mod+Shift+Equal" = ''set-window-height "+10%"'';
    "Mod+V" = "toggle-window-floating";
    "Mod+Shift+V" = "switch-focus-between-floating-and-tiling";
    "Mod+W" = "toggle-column-tabbed-display";

    # Workspaces
    "Mod+U" = "focus-workspace-down";
    "Mod+I" = "focus-workspace-up";
    "Mod+Page_Down" = "focus-workspace-down";
    "Mod+Page_Up" = "focus-workspace-up";
    "Mod+Ctrl+U" = "move-column-to-workspace-down";
    "Mod+Ctrl+I" = "move-column-to-workspace-up";
    "Mod+Ctrl+Page_Down" = "move-column-to-workspace-down";
    "Mod+Ctrl+Page_Up" = "move-column-to-workspace-up";
    "Mod+Shift+U" = "move-workspace-down";
    "Mod+Shift+I" = "move-workspace-up";
    "Mod+WheelScrollDown" = { action = "focus-workspace-down"; cooldown-ms = 150; };
    "Mod+WheelScrollUp" = { action = "focus-workspace-up"; cooldown-ms = 150; };
    "Mod+WheelScrollRight" = "focus-column-right";
    "Mod+WheelScrollLeft" = "focus-column-left";
    "Mod+Shift+WheelScrollDown" = "focus-column-right";
    "Mod+Shift+WheelScrollUp" = "focus-column-left";

    # Screenshots
    "Print" = "screenshot";
    "Ctrl+Print" = "screenshot-screen";
    "Alt+Print" = "screenshot-window";

    # Media & hardware keys
    "XF86AudioRaiseVolume" = media (spawnSh "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.05+ -l 1.0");
    "XF86AudioLowerVolume" = media (spawnSh "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.05-");
    "XF86AudioMute" = media (spawnSh "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle");
    "XF86AudioMicMute" = media (spawnSh "wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle");
    "XF86AudioPlay" = media (spawnSh "playerctl play-pause");
    "XF86AudioStop" = media (spawnSh "playerctl stop");
    "XF86AudioPrev" = media (spawnSh "playerctl previous");
    "XF86AudioNext" = media (spawnSh "playerctl next");
    "XF86MonBrightnessUp" = media (spawn [ "brightnessctl" "--class=backlight" "set" "+5%" ]);
    "XF86MonBrightnessDown" = media (spawn [ "brightnessctl" "--class=backlight" "set" "5%-" ]);

    # Session
    "Mod+Escape" = { action = "toggle-keyboard-shortcuts-inhibit"; allow-inhibiting = false; };
    "Mod+Shift+E" = "quit";
    "Ctrl+Alt+Delete" = "quit";
    "Mod+Shift+P" = "power-off-monitors";
  };

  bindOption = lib.types.either lib.types.str (lib.types.attrsOf (lib.types.oneOf [
    lib.types.str lib.types.bool lib.types.int
  ]));
in
{
  options.smudgenix.desktop.binds = lib.mkOption {
    type = lib.types.attrsOf (lib.types.nullOr bindOption);
    default = { };
    example = lib.literalExpression ''
      {
        "Mod+T" = '''spawn "alacritty"''';
        "Mod+Shift+P" = null;
      }
    '';
    description = ''
      Keybinds for tiling sessions (niri), as niri actions. Set a bind to
      null to remove it.
    '';
  };

  config.smudgenix.desktop.binds = lib.mapAttrs (_: lib.mkDefault) defaults;
}
