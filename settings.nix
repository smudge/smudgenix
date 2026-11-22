# smudgenix.toml: the settings `smx config` writes, next to a host or home
# flake (which passes it as `settings` to mkSystem or mkHome). Each key is a
# `smudgenix.*` option, and wins over the same option set in flake.nix.
{ lib }:

{
  # (In both the OS's and homes' modules.) Where this config's settings
  # come from, for smx.
  module = {
    options.smudgenix.settingsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      internal = true;
      description = "The smudgenix.toml this config reads, if any.";
    };
  };

  fromFile = file: {
    _file = toString file;
    config = lib.mkMerge [
      { smudgenix.settingsFile = toString file; }
      # (Not mkIf, which would read the file to see what it sets.)
      (if builtins.pathExists file then {
        smudgenix = lib.mapAttrsRecursive (_: lib.mkOverride 90)
          (builtins.fromTOML (builtins.readFile file));
      } else { })
    ];
  };
}
