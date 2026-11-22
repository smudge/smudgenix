# Pieces of niri's config (KDL), shared by the OS's config (./niri.nix) and
# each home's overrides (../../nix/modules/desktop.nix).
{ lib }:

let
  kdlValue = v:
    if lib.isBool v then lib.boolToString v
    else if lib.isInt v then toString v
    else builtins.toJSON v;
  lines = lib.concatStringsSep "\n";
in
rec {
  # A bind: a niri action string, or an attrset of { action; <bind options> }
  # (e.g. repeat = false).
  bindType = lib.types.either lib.types.str (lib.types.attrsOf (lib.types.oneOf [
    lib.types.str lib.types.bool lib.types.int
  ]));

  bind = key: value: let
    b = if lib.isString value then { action = value; } else value;
    opts = lib.mapAttrsToList (k: v: " ${k}=${kdlValue v}") (removeAttrs b [ "action" ]);
  in "    ${key}${lib.concatStrings opts} { ${b.action}; }";

  binds = attrs: lines ([ "binds {" ] ++ lib.mapAttrsToList bind attrs ++ [ "}" ]);

  keyboard = { delay ? null, rate ? null }: lines ([ "keyboard {" ]
    ++ lib.optional (delay != null) "    repeat-delay ${toString delay}"
    ++ lib.optional (rate != null) "    repeat-rate ${toString rate}"
    ++ [ "}" ]);

  # (niri doesn't merge touchpad sections across files, so this is always
  # the whole of it.)
  touchpad = { tap }: lines ([
      "touchpad {"
      "    // Click by pressing down (and tapping, with `touchpad.tapToClick`)."
    ]
    ++ lib.optional tap "    tap"
    ++ [
      "    natural-scroll"
      "    // Two-finger click to right-click, rather than the bottom-right"
      "    // corner (as GNOME does). Touchpads with buttons keep them."
      "    click-method \"clickfinger\""
      "}"
    ]);

  # A section, indented to sit inside another (interpolated after 4 spaces).
  nested = s: lib.concatStringsSep "\n    " (lib.splitString "\n" s);

  # Where each user's home flake writes its overrides (read last, so they
  # win).
  homeFile = "~/.config/niri/smudgenix.kdl";
}
