# The shortcuts sheet that holding Super shows (../../noctalia/plugins/
# shortcuts), from the binds (./binds.nix): just Super's, in sections, written
# without "Super+" (it's held already), and with families like Super+1…9 on
# one line. Spawns show only with a hotkey-overlay-title, and binds that open
# something on the bar (`onBar`, panels' ids) only there, on its buttons.
#
# Gives { sheet; keysFor }: keysFor.<panel> is what opens it, like "Space".
{ lib }:

{ binds, onBar ? [ ] }:

let
  actionOf = v: if lib.isString v then v else v.action;
  titleOf = v: if lib.isAttrs v then v.hotkey-overlay-title or null else null;

  keyNames = {
    Return = "Enter"; Escape = "Esc"; Slash = "/"; Comma = ","; Period = ".";
    Minus = "-"; Equal = "="; BracketLeft = "["; BracketRight = "]"; Space = "Space";
  };
  # "Mod+Ctrl+Return" -> [ "Ctrl" "Enter" ], or null if it isn't Super's.
  keysOf = key: let parts = lib.splitString "+" key; in
    if lib.elem (lib.head parts) [ "Mod" "Super" ]
    then map (p: keyNames.${p} or p) (lib.tail parts)
    else null;

  # "set-column-width \"-10%\"" -> "Set column width -10%"
  humanize = action: let
    words = lib.splitString " " (lib.replaceStrings [ "\"" ] [ "" ] action);
    text = lib.concatStringsSep " " ([ (lib.replaceStrings [ "-" ] [ " " ] (lib.head words)) ] ++ lib.tail words);
  in lib.toUpper (lib.substring 0 1 text) + lib.substring 1 (-1) text;

  directions = { H = "left"; J = "down"; K = "up"; L = "right"; };
  digits = map toString (lib.range 1 9);

  # The panel a bind opens, if it does (see ./noctalia.nix's `msg`).
  panelOf = action: let
    m = builtins.match "spawn \"noctalia\" \"msg\" \"panel-(toggle|open)\" \"([^\"]+)\".*" action;
  in if m == null then null else lib.elemAt m 1;

  # One entry per bind: { section, keys, title } (or null, to leave it out).
  entry = key: value: let
    keys = keysOf key;
    last = lib.last keys;
    action = actionOf value;
    title = titleOf value;
    name = lib.head (lib.splitString " " action);
    hasWord = w: lib.hasInfix w name;
    section =
      if title != null && lib.hasPrefix "spawn" action then "Open"
      else if hasWord "workspace" then "Workspaces"
      else if hasWord "monitor" then "Monitors"
      else if family != null || lib.hasSuffix "-first" name || lib.hasSuffix "-last" name then "Move around"
      else if lib.any hasWord [ "width" "height" "maximize" "fullscreen" ] then "Size"
      else if lib.any hasWord [ "window" "column" "floating" ] then "Windows"
      else "Session";
    # (Families: H/J/K/L for directions, 1…9 for workspaces.)
    family =
      if directions ? ${last} && lib.hasSuffix "-${directions.${last}}" name then {
        keys = lib.init keys ++ [ "H J K L" ];
        title = humanize (lib.removeSuffix "-column" (lib.removeSuffix "-window"
          (lib.removeSuffix "-${directions.${last}}" name)));
      } else if lib.elem last digits && lib.hasSuffix " ${last}" action then {
        keys = lib.init keys ++ [ "1…9" ];
        title = humanize name;
      } else null;
  in
    if keys == null || lib.any (p: lib.hasPrefix "XF86" p || lib.hasPrefix "Wheel" p
      || lib.elem p [ "Left" "Right" "Up" "Down" "Page_Up" "Page_Down" ]) keys
      || (lib.hasPrefix "spawn" action && title == null)
      || lib.elem (panelOf action) onBar
    then null
    else { inherit section; } // (if family != null then family else {
      inherit keys;
      title = if title != null then title else humanize action;
    });

  bound = lib.filterAttrs (_: v: v != null) binds;
  entries = lib.unique (lib.filter (e: e != null) (lib.mapAttrsToList entry bound));
in
{
  keysFor = lib.foldlAttrs (acc: key: value: let
    panel = panelOf (actionOf value);
    keys = keysOf key;
  in if panel == null || keys == null || acc ? ${panel} then acc
    else acc // { ${panel} = lib.concatStringsSep "+" keys; }) { } bound;

  sheet = lib.filter (s: s.binds != [ ]) (map (section: {
    title = section;
    binds = map (e: { keys = lib.concatStringsSep "+" e.keys; inherit (e) title; })
      (lib.filter (e: e.section == section) entries);
  }) [ "Open" "Move around" "Windows" "Size" "Workspaces" "Monitors" "Session" ]);
}
