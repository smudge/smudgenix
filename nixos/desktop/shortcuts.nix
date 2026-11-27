# The shortcuts sheet that holding Super shows (../../noctalia/plugins/
# shortcuts), from niri binds: just Super's, in sections, written without
# "Super+" (it's held already), and with families like Super+1…9 on one line.
# Spawns show only with a hotkey-overlay-title. Keys that do the same thing
# share a line, and those that open something on the bar have its icon.
#
# All worked out here, as the OS and a home build, so the panel only reads
# it: the OS's (./leader.nix) and a home's own binds (../../nix/modules/
# desktop.nix), over it.
{ lib }:

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

  # A bind's key as niri matches it, to tell when a home's replaces the OS's:
  # "Super+Shift+Ctrl+H" and "Mod+Ctrl+Shift+H" are both "Ctrl+Mod+Shift+H".
  canonical = key: let
    parts = map (p: if p == "Super" then "Mod" else p) (lib.splitString "+" key);
  in lib.concatStringsSep "+" (lib.sort lib.lessThan (lib.init parts) ++ [ (lib.last parts) ]);

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

  # Noctalia's pills (and smudgenix's), by widget type: what clicking one
  # opens, and its icon unless it's given one (`glyph`).
  pills = {
    launcher = { panel = "launcher"; glyph = "search"; };
    clipboard = { panel = "clipboard"; glyph = "clipboard"; };
    control-center = { panel = "control-center"; glyph = "noctalia"; };
    "smudgenix/agents:agents" = { panel = "smudgenix/agents:sessions"; glyph = "robot"; };
    volume = { panel = "control-center audio"; glyph = "volume"; };
    media = { panel = "control-center media"; glyph = "music"; };
    brightness = { panel = "control-center monitor"; glyph = "brightness-high"; };
    battery = { panel = "control-center power"; glyph = "battery-4"; };
    network = { panel = "control-center network"; glyph = "wifi"; };
    bluetooth = { panel = "control-center bluetooth"; glyph = "bluetooth"; };
    clock = { panel = "control-center calendar"; glyph = "clock"; };
    notifications = { panel = "control-center notifications"; glyph = "bell"; };
    session = { panel = "session"; glyph = "power"; };
  };

  # The bar's icons by what they open, from Noctalia settings: its widgets
  # (`widget.<name>`, and those its bars list), with their own `glyph` and
  # click (`actions.left`) over Noctalia's, every pill's by default. With
  # `defaults = false`, only those given a glyph (a home's, over the OS's).
  glyphsOf = { settings, defaults ? true }: let
    widgets = settings.widget or { };
    listed = lib.concatMap (bar: bar.start or [ ] ++ bar.center or [ ] ++ bar.end or [ ])
      (lib.filter lib.isAttrs (lib.attrValues (settings.bar or { })));
    names = lib.unique (listed ++ lib.attrNames widgets);
    pillOf = name: let
      w = widgets.${name} or { };
      type = w.type or name;
      clicked = builtins.match "panel-(toggle|open) ([^ ]+)( ([^ ]+))?" (w.actions.left or "");
      panel = if clicked != null
        then lib.elemAt clicked 1 + lib.optionalString (lib.elemAt clicked 3 != null) " ${lib.elemAt clicked 3}"
        else pills.${type}.panel or null;
      glyph = w.glyph or (if defaults then pills.${type}.glyph or null else null);
    in if panel == null || glyph == null then null else lib.nameValuePair panel glyph;
  in lib.optionalAttrs defaults (lib.mapAttrs' (_: p: lib.nameValuePair p.panel p.glyph) pills)
    // lib.listToAttrs (lib.filter (p: p != null) (map pillOf names));

  sections = [ "Open" "The bar" "Move around" "Windows" "Size" "Workspaces" "Monitors" "Session" ];

  # (In order by number, as people count: F4 before F10.)
  natural = s: lib.concatMapStrings (p: if lib.isList p then lib.fixedWidthString 3 "0" (lib.head p) else p)
    (builtins.split "([0-9]+)" s);

  # { order; sections; glyphs; replaces } for the panel, from niri binds and
  # the icons by panel (glyphsOf). Each line is { title, glyph, panel,
  # prefix, parts, sort }: its keys are `prefix` and its parts', each with
  # the binds it stands for and their own keys (`members`: H, J, K and L for
  # "H J K L"), so the panel can leave out those a home replaced.
  sheet = { binds, glyphs ? { } }: let
    # One entry per bind: { section, keys, title, glyph, panel, binds } (or
    # null, to leave it out).
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
      else let
        own = { inherit keys; title = if title != null then title else humanize action; };
      in { inherit section glyph panel own; binds = [ (canonical key) ]; members = [ last ]; }
        // (if family != null then family else own);

    bound = lib.filterAttrs (_: v: v != null) binds;
    # (A family's binds, as one: unless there's only one of it.)
    entries = map (same: if lib.length same == 1 then lib.head same // (lib.head same).own
      else lib.head same // { binds = lib.concatMap (e: e.binds) same; members = lib.concatMap (e: e.members) same; })
      (lib.attrValues (lib.groupBy (e: builtins.toJSON [ e.section e.title e.keys ])
        (lib.filter (e: e != null) (lib.mapAttrsToList entry bound))));

    # Keys that do the same thing, on one line: F1 F2 F3, Shift+F7 F8.
    byLength = a: b: if lib.stringLength (lib.last a.keys) != lib.stringLength (lib.last b.keys)
      then lib.stringLength (lib.last a.keys) < lib.stringLength (lib.last b.keys)
      else lib.last a.keys < lib.last b.keys;
    lineOf = same: let
      first = lib.head same;
      init = lib.init first.keys;
      prefix = lib.concatMapStrings (k: "${k}+") init;
      parts = map (e: { key = lib.last e.keys; inherit (e) binds members; }) same;
    in {
      inherit (first) section title;
      inherit prefix parts;
      sort = natural (prefix + lib.concatMapStringsSep " " (p: p.key) parts);
    } // lib.optionalAttrs (first.glyph != null) { inherit (first) glyph panel; };
    lines = lib.concatMap (same: let init = lib.init (lib.head same).keys; in
      if lib.all (e: lib.init e.keys == init) same
      then [ (lineOf (lib.sort byLength same)) ]
      else map (e: lineOf [ e ]) same)
      (lib.attrValues (lib.groupBy (e: "${e.section}\t${e.title}") entries));
  in {
    order = sections;
    inherit glyphs;
    replaces = map canonical (lib.attrNames bound);
    sections = lib.filter (s: s.binds != [ ]) (map (section: {
      title = section;
      binds = map (l: removeAttrs l [ "section" ])
        (lib.sort (a: b: a.sort < b.sort) (lib.filter (l: l.section == section) lines));
    }) sections);
  };
in
{
  inherit pills glyphsOf sheet;
}
