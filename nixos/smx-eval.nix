# Answers smx's questions about a host's or home's smudgenix options, as JSON:
#
#   nix eval --json <flake>#<config> --apply 'c: import ./smx-eval.nix c <request>'
#
# where <request> is { list = true; } (every option), { path = [ … ]; } (one
# option, or a value inside one, like [ "desktop" "binds" "Mod+T" ]), or
# { check = [ … ]; } (true, or the error in that value).
c: request:

let
  inherit (c.pkgs) lib;
  opts = c.options.smudgenix;
  cfg = c.config.smudgenix;
  settingsFile = cfg.settingsFile or null;

  # A value, as JSON can show it.
  plain = v:
    let r = builtins.tryEval (
      if lib.isDerivation v then "<package ${lib.getName v}>"
      else if lib.isFunction v then "<function>"
      else if builtins.isPath v then toString v
      else if lib.isAttrs v then lib.mapAttrs (_: plain) v
      else if lib.isList v then map plain v
      else v);
    in if r.success then r.value else "<error>";

  # Where an option's value comes from.
  origin = opt:
    if settingsFile != null && lib.elem settingsFile opt.files then "smudgenix.toml"
    else if lib.any (f: baseNameOf f == "flake.nix") opt.files then "flake.nix"
    else "default";

  describe = path: opt: {
    key = lib.concatStringsSep "." path;
    type = opt.type.description;
    typeName = opt.type.name;
    description = opt.description or "";
    default =
      if opt ? defaultText then opt.defaultText.text or (plain opt.defaultText)
      else if opt ? default then builtins.toJSON (plain opt.default)
      else null;
    value = plain (lib.attrByPath path null cfg);
    origin = origin opt;
  };

  shown = opt: (opt.visible or true) == true && !(opt.internal or false) && !(opt.readOnly or false);

  all = lib.collect lib.isOption opts;

  # The longest leading part of `path` that names an option.
  optionAt = path:
    let
      n = lib.findFirst
        (i: lib.isOption (lib.attrByPath (lib.take i path) null opts))
        null
        (lib.reverseList (lib.range 1 (lib.length path)));
    in if n == null then null else lib.take n path;

  one = path:
    let at = optionAt path; in
    if at == null || !(shown (lib.getAttrFromPath at opts)) then {
      error = "unknown";
      # Close matches: options under the given path, or sharing its last part.
      suggestions = map (o: lib.concatStringsSep "." (lib.drop 1 o.loc))
        (lib.filter (o: shown o && (lib.lists.hasPrefix path (lib.drop 1 o.loc)
          || lib.elem (lib.last path) o.loc)) all);
    } else describe at (lib.getAttrFromPath at opts) // {
      inherit settingsFile;
      # (Within the option's value, when the path goes further.)
      inner = lib.drop (lib.length at) path;
      value = plain (lib.attrByPath path null cfg);
    };
  # Evaluates a value fully (but not into packages), so its errors show.
  force = v:
    if lib.isDerivation v then true
    else if lib.isAttrs v then lib.all force (lib.attrValues v)
    else if lib.isList v then lib.all force v
    else builtins.seq v true;
in
if request ? list then
  map (o: describe (lib.drop 1 o.loc) o) (lib.filter shown all)
else if request ? check then
  force (lib.attrByPath request.check null cfg)
else
  one request.path
