# Adopt Noctalia GUI tweaks into this home flake. Noctalia's Settings saves
# changes to ~/.local/state/noctalia/settings.toml (layered over the system's
# config). Settings declared here are merged into that file on every switch,
# overwriting those keys and leaving the rest of your tweaks alone, much like
# home-manager's `dconf.settings`. Delete the file to reset every tweak.
{ config, pkgs, lib, ... }:

let
  cfg = config.smudgenix.noctalia;
  declared = pkgs.writeText "noctalia-settings.json" (builtins.toJSON cfg.settings);
in
{
  options.smudgenix.noctalia.settings = lib.mkOption {
    inherit ((pkgs.formats.toml { })) type;
    default = { };
    example = { bar.default.position = "bottom"; };
    description = "Noctalia settings to apply over the system's defaults.";
  };

  config = lib.mkIf (pkgs.stdenv.hostPlatform.isLinux && cfg.settings != { }) {
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
  };
}
