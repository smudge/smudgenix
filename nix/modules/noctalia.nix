# Adopt Noctalia GUI tweaks into this home flake. Noctalia's Settings saves
# changes to ~/.local/state/noctalia/settings.toml (layered over the system's
# config). Settings declared here are merged into that file on every switch,
# overwriting those keys and leaving the rest of your tweaks alone, much like
# home-manager's `dconf.settings`. Delete the file to reset every tweak.
#
# And smudgenix's Noctalia plugins, live from a checkout, to work on them.
{ config, pkgs, lib, ... }:

let
  cfg = config.smudgenix.desktop.noctalia;
  declared = pkgs.writeText "noctalia-settings.json" (builtins.toJSON cfg.settings);
  inherit (pkgs.stdenv.hostPlatform) isLinux;
  pluginNames = builtins.attrNames (lib.filterAttrs (_: type: type == "directory")
    (builtins.readDir ../../noctalia/plugins));
in
{
  # (Named like the OS's `smudgenix.desktop.noctalia.settings`.)
  imports = [
    (lib.mkRenamedOptionModule [ "smudgenix" "noctalia" "settings" ] [ "smudgenix" "desktop" "noctalia" "settings" ])
  ];

  options.smudgenix.desktop.noctalia.settings = lib.mkOption {
    inherit ((pkgs.formats.toml { })) type;
    default = { };
    example = { bar.default.position = "bottom"; };
    description = "Noctalia settings to apply over the system's defaults.";
  };

  options.smudgenix.desktop.noctalia.pluginsFrom = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "/home/me/src/smudgenix";
    description = ''
      A smudgenix checkout whose Noctalia plugins (noctalia/plugins/) to use
      instead of the OS's. Noctalia reloads them as you edit them.
    '';
  };

  config = lib.mkMerge [
    (lib.mkIf (isLinux && cfg.pluginsFrom != null) {
      # (Noctalia's own plugin folder, which wins over every plugin source.)
      xdg.dataFile = lib.listToAttrs (map (name: {
        name = "noctalia/plugins/${name}";
        value.source = config.lib.file.mkOutOfStoreSymlink "${cfg.pluginsFrom}/noctalia/plugins/${name}";
      }) pluginNames);
    })

    (lib.mkIf (isLinux && cfg.settings != { }) {
      home.activation.smudgenixNoctalia = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        noctalia_state="''${XDG_STATE_HOME:-$HOME/.local/state}/noctalia"
        noctalia_settings="$noctalia_state/settings.toml"
        run mkdir -p "$noctalia_state"
        noctalia_tmp=$(mktemp)
        { if [ -s "$noctalia_settings" ]; then ${lib.getExe pkgs.yj} -tj < "$noctalia_settings"; else echo '{}'; fi; } \
          | ${lib.getExe pkgs.jq} -s '.[0] * .[1]' - ${declared} \
          | ${lib.getExe pkgs.yj} -jt > "$noctalia_tmp"
        run mv "$noctalia_tmp" "$noctalia_settings"
      '';
    })
  ];
}
