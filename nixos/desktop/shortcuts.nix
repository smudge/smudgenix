# The shortcuts sheet that holding Super shows (../../noctalia/plugins/
# shortcuts), from the binds (./binds.nix): just Super's, in sections, written
# without "Super+" (it's held already), and with families like Super+1…9 on
# one line. Spawns show only with a hotkey-overlay-title. Keys that do the
# same thing share a line, and those that open something on the bar (`glyphs`,
# its icon by panel, and page: "control-center audio") have its icon.
{ lib }:

{ binds, glyphs ? { } }:

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

  # The panel a bind opens, if it does (see ./noctalia.nix's `msg`), with
  # its page if it has one: "launcher", "control-center audio".
  panelOf = action: let
    m = builtins.match "spawn \"noctalia\" \"msg\" \"panel-(toggle|open)\" \"([^\"]+)\"( \"([^\"]+)\")?" action;
  in if m == null then null
    else lib.elemAt m 1 + lib.optionalString (lib.elemAt m 3 != null) " ${lib.elemAt m 3}";

  # One entry per bind: { section, keys, title, glyph } (or null, to leave it
  # out).
  entry = key: value: let
    keys = keysOf key;
    last = lib.last keys;
    action = actionOf value;
    title = titleOf value;
    panel = panelOf action;
    glyph = if panel != null then glyphs.${panel} or null else null;
    name = lib.head (lib.splitString " " action);
    hasWord = w: lib.hasInfix w name;
    section =
      if glyph != null then "The bar"
      else if title != null && lib.hasPrefix "spawn" action then "Open"
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
    # (Media keys and Print are another key's, with Fn-lock off.)
    if keys == null || lib.any (p: lib.hasPrefix "XF86" p || lib.hasPrefix "Wheel" p
      || lib.elem p [ "Left" "Right" "Up" "Down" "Page_Up" "Page_Down" "Print" ]) keys
      || (lib.hasPrefix "spawn" action && title == null)
    then null
    else { inherit section glyph; } // (if family != null then family else {
      inherit keys;
      title = if title != null then title else humanize action;
    });

  bound = lib.filterAttrs (_: v: v != null) binds;
  entries = lib.unique (lib.filter (e: e != null) (lib.mapAttrsToList entry bound));

  # Keys that do the same thing, on one line: F1 F2 F3, Shift+F7 F8.
  byLength = a: b: if lib.stringLength a != lib.stringLength b
    then lib.stringLength a < lib.stringLength b else a < b;
  lines = lib.concatMap (same: let
    init = lib.init (lib.head same).keys;
  in if lib.length same > 1 && lib.all (e: lib.init e.keys == init) same
    then [ ((lib.head same) // {
      keys = init ++ [ (lib.concatStringsSep " " (lib.sort byLength (map (e: lib.last e.keys) same))) ];
    }) ]
    else same) (lib.attrValues (lib.groupBy (e: "${e.section}\t${e.title}") entries));
  joined = e: lib.concatStringsSep "+" e.keys;
  # (In order by number, as people count: F4 before F10.)
  natural = s: lib.concatMapStrings (p: if lib.isList p then lib.fixedWidthString 3 "0" (lib.head p) else p)
    (builtins.split "([0-9]+)" s);
in
{
  sheet = lib.filter (s: s.binds != [ ]) (map (section: {
    title = section;
    binds = map (e: { keys = joined e; inherit (e) title; }
      // lib.optionalAttrs (e.glyph != null) { inherit (e) glyph; })
      (lib.sort (a: b: natural (joined a) < natural (joined b))
        (lib.filter (e: e.section == section) lines));
  }) [ "Open" "The bar" "Move around" "Windows" "Size" "Workspaces" "Monitors" "Session" ]);
}
